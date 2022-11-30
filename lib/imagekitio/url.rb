# frozen_string_literal: true

# Url holds url generation method

require "cgi"
require "addressable/uri"
require "openssl"
require_relative "./utils/formatter"
require_relative "sdk/version.rb"

module ImageKitIo
  class Url
    include Constantable

    def initialize(request_obj)
      @req_obj = request_obj
    end

    def generate_url(options)
      if options.key? :src
        options[:transformation_position] = constants.TRANSFORMATION_POSITION
      end
      extended_options = extend_url_options(options)
      build_url(extended_options)
    end

    def build_url(options)
      # build url from all options

      path = options.fetch(:path, "")
      src = options.fetch(:src, "")
      url_endpoint = options.fetch(:url_endpoint, "")
      transformation_position = options[:transformation_position]

      unless constants.VALID_TRANSFORMATION_POSITION.include? transformation_position
        raise ArgumentError, constants.INVALID_TRANSFORMATION_POS
      end

      src_param_used_for_url = false
      if (src != "") || (transformation_position == constants.QUERY_TRANSFORMATION_POSITION)
        src_param_used_for_url = true
      end

      if path == "" && src == ""
        return ""
      end

      result_url_hash = {'host': "", 'path': "", 'query': ""}
      parsed_host = Addressable::URI.parse(url_endpoint)
      existing_query = nil
      if path != ""
        parsed_url = Addressable::URI.parse(path)
        # making sure single '/' at end
        result_url_hash[:host] = parsed_host.host.to_s.chomp("/") + parsed_host.path.chomp("/") + "/"
        path_without_query = Addressable::URI.parse(path)
        path_without_query.fragment = path_without_query.query = nil
        result_url_hash[:path] = path_without_query.hostname.nil? ? trim_slash(path_without_query.to_s) : CGI.escape(trim_slash(path_without_query.to_s))
      else
        parsed_url = Addressable::URI.parse(src)
        result_url_hash[:userinfo] = parsed_url.userinfo if parsed_url.userinfo
        result_url_hash[:host] = parsed_url.host
        result_url_hash[:path] = parsed_url.path
        src_param_used_for_url = true
      end

      existing_query = parsed_url.query
      result_url_hash[:scheme] = parsed_host.scheme
      query_params = {}
      query_params = CGI.parse(existing_query).reject {|k, v| v.empty? }.transform_values(&:first) unless existing_query.nil?
      options.fetch(:query_parameters, {}).each do |key, value|
        query_params[key] = value
      end
      transformation_str = transformation_to_str(options[:transformation]).chomp("/")
      unless transformation_str.nil? || transformation_str.strip.empty?
        if (transformation_position == constants.QUERY_TRANSFORMATION_POSITION) || src_param_used_for_url == true
          result_url_hash[:query] = "#{constants.TRANSFORMATION_PARAMETER}=#{transformation_str}"
          query_params[:tr]=transformation_str
        else
          result_url_hash[:path] = "#{constants.TRANSFORMATION_PARAMETER}:#{transformation_str}/#{result_url_hash[:path]}"
        end
      end

      result_url_hash[:host] = result_url_hash[:host].to_s.reverse.chomp("/").reverse
      result_url_hash[:path] = result_url_hash[:path].chomp("/") unless result_url_hash[:path].nil?
      result_url_hash[:scheme] ||= "https"

      query_param_arr = []
      query_params.each do |key, value|
        if value.to_s == ""
          query_param_arr.push(key.to_s)
        else
          query_param_arr.push(key.to_s + "=" + value.to_s)
        end
      end
      query_param_str = query_param_arr.join("&")
      result_url_hash[:query] = query_param_str
      url = hash_to_url(result_url_hash)
      if options[:signed]
        private_key = options[:private_key]
        expire_seconds = options[:expire_seconds]
        expire_timestamp = get_signature_timestamp(expire_seconds)
        url_signature = get_signature(private_key, url, url_endpoint, expire_timestamp)
        query_param_arr.push(constants.SIGNATURE_PARAMETER + "=" + url_signature)

        if expire_timestamp && (expire_timestamp != constants.TIMESTAMP)
          query_param_arr.push(constants.TIMESTAMP_PARAMETER + "=" + expire_timestamp.to_s)
        end
        query_param_str = query_param_arr.join("&")
        result_url_hash[:query] = query_param_str

        url=hash_to_url(result_url_hash)
      end
      url
    end

    def transformation_to_str(transformation)
      # creates transformation_position string for url
      # from transformation dictionary

      unless transformation.is_a?(Array)
        return ""
      end

      parsed_transforms = []
      (0..(transformation.length - 1)).each do |i|
        parsed_transform_step = []

        transformation[i].keys.each do |key|
          transform_key = constants.SUPPORTED_TRANS.fetch(key, nil)
          transform_key ||= key

          if transform_key == "oi" || transform_key == "di"
            transformation[i][key][0] = "" if transformation[i][key][0] == "/"
            transformation[i][key] = transformation[i][key].gsub("/", "@@")
          end

          if transformation[i][key] == "-"
            parsed_transform_step.push(transform_key)
          elsif transform_key == 'raw'
            parsed_transform_step.push(transformation[i][key])
          else
            parsed_transform_step.push("#{transform_key}#{constants.TRANSFORM_KEY_VALUE_DELIMITER}#{transformation[i][key]}")
          end
        end
        parsed_transforms.push(parsed_transform_step.join(constants.TRANSFORM_DELIMITER))
      end
      parsed_transforms.join(constants.CHAIN_TRANSFORM_DELIMITER)
    end

    def get_signature_timestamp(seconds)
      # this function returns either default time stamp
      # or current unix time and expiry seconds to get
      # signature time stamp

      if seconds.to_i == 0
        constants.DEFAULT_TIMESTAMP
      else
        DateTime.now.strftime("%s").to_i + seconds.to_i
      end
    end

    def get_signature(private_key, url, url_endpoint, expiry_timestamp)
      # creates signature(hashed hex key) and returns from
      # private_key, url, url_endpoint and expiry_timestamp
      if expiry_timestamp==0
        expiry_timestamp=constants.DEFAULT_TIMESTAMP
      end
      if url_endpoint[url_endpoint.length-1]!="/"
        url_endpoint+="/"
      end
      replaced_url=url.gsub(url_endpoint, "")
      replaced_url =  replaced_url + expiry_timestamp.to_s
      OpenSSL::HMAC.hexdigest("SHA1", private_key, replaced_url)
    end

    def extend_url_options(options)
      attr_dict = {"public_key": @req_obj.public_key,
                   "private_key": @req_obj.private_key,
                   "url_endpoint": @req_obj.url_endpoint,
                   "transformation_position": @req_obj.transformation_position, }
      # extending  url options
      attr_dict.merge(options)
    end

    def hash_to_url(url_hash)
      generated_url = url_hash.fetch(:scheme, "") + "://" + url_hash.fetch(:host, "") + url_hash.fetch(:path, "")
      if url_hash[:query] != ""
        generated_url = generated_url + "?" + url_hash.fetch(:query, "")
        return generated_url
      end
      generated_url
    end

    def trim_slash(str, both = true)
      if str == ""
        return ""
      end
      # remove slash from a string
      # if both is not provide trims both slash
      # example - '/abc/' returns 'abc'
      # if both=false it will only trim end slash
      # example - '/abc/' returns '/abc'
      # NOTE: IT'S RECOMMENDED TO USE inbuilt .chomp('string you want to remove')
      # FOR REMOVING ONLY TRAILING SLASh
      if both
        str[0].chomp("/") + str[1..-2] + str[-1].chomp("/")
      else
        str.chomp("/")
      end
    end

    # class Imagekit

    # end
  end
end
