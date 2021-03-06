# Copyright 2011 Rapleaf
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.

require "json"
require "net/https"
require "timeout"
require "digest"
require "open-uri"
require "towerdata_api/configuration"
require "towerdata_api/errors"
require "towerdata_api/email_validation"

module TowerDataApi
  HOST= "api.towerdata.com".freeze
  PORT= 443.freeze
  HEADERS = {'User-Agent' => 'TowerDataApi/Ruby/1.3'}.freeze
  API_VERSION= 5.freeze
  BASE_PATH= '/td'.freeze
  BULK_PATH= '/ei/bulk'.freeze

  class Api

    def initialize(api_key=nil, options = {})
      @api_key = api_key.nil? ? Configuration.api_key : api_key
      options.each do |key, value|
        Configuration.send("#{key}=", value)
      end 
    end

    # Takes an e-mail and returns a hash which maps attribute fields onto attributes
    # Options:
    #  :hash_email     - the email will be hashed before it's sent to Rapleaf
    def query_by_email(email, options = {})
      if options[:hash_email]
        query_by_sha1(Digest::SHA1.hexdigest(email.downcase))
      else
        get_json_response("#{base_path}&email=#{url_encode(email)}")
      end
    end

    # Takes an e-mail that has already been hashed by md5
    # and returns a hash which maps attribute fields onto attributes,
    # optionally showing available data in the response
    def query_by_md5(md5_email, options = {})
      get_json_response("#{base_path}&md5_email=#{url_encode(md5_email)}")
    end

    # Takes an e-mail that has already been hashed by sha1
    # and returns a hash which maps attribute fields onto attributes,
    # optionally showing available data in the response
    def query_by_sha1(sha1_email, options = {})
      get_json_response("#{base_path}&sha1_email=#{url_encode(sha1_email)}")
    end

    # Takes first name, last name, and postal (street, city, and state acronym),
    # and returns a hash which maps attribute fields onto attributes
    # Options:
    #  :email          - query with an email to increase the hit rate
    def query_by_nap(first, last, street, city, state, options = {})
      if options[:email]
        url = "#{base_path}&email=#{url_encode(options[:email])}&first=#{url_encode(first)}&last=#{url_encode(last)}" +
          "&street=#{url_encode(street)}&city=#{url_encode(city)}&state=#{url_encode(state)}"
      else
        url = "#{base_path}&first=#{url_encode(first)}&last=#{url_encode(last)}" +
          "&street=#{url_encode(street)}&city=#{url_encode(city)}&state=#{url_encode(state)}"
      end
      get_json_response(url)
    end

    # Takes first name, last name, and zip4 code (5-digit zip 
    # and 4-digit extension separated by a dash as a string),
    # and returns a hash which maps attribute fields onto attributes
    # Options:
    #  :email          - query with an email to increase the hit rate
    def query_by_naz(first, last, zip4, options = {})
      if options[:email]
        url = "#{base_path}&email=#{url_encode(options[:email])}&first=#{url_encode(first)}&last=#{url_encode(last)}&zip4=#{zip4}"
      else
        url = "#{base_path}&first=#{url_encode(first)}&last=#{url_encode(last)}&zip4=#{zip4}"
      end
      get_json_response(url)
    end


    # For given email returns EmailValidation object
    # This method will rise TowerDataApi::Error::Unsupported 
    # if yours api key doesn't have email validation field 
    #
    def email_validation email
      begin
        result = query_by_email email
      rescue TowerDataApi::Error::BadRequest 
        result = {'email_validation' => {'ok' => false}}
      end

      if result.has_key? 'email_validation'
        EmailValidation.new result['email_validation']
      else
        raise TowerDataApi::Error::Unsupported, 'Email validation is not supported with yours api key.' 
      end
    end

    # Check is email valid
    # This method will rise TowerDataApi::Error::Api 
    # if yours api key doesn't have email validation field 
    # Value can be true, false and nil 
    def valid_email? email
      email_validation(email).valid?
    end


    # Get bulk request 
    # set - is array of hashes in format
    #
    #  [{email: 'first_email'}, {email: 'second_email'}]
    #
    def bulk_query(set)
      get_bulk_response(bulk_path, JSON.generate(set))
    end

    private

    def url_encode value 
       URI::encode value
    end

    def get_bulk_response(path, data)
      response = Timeout::timeout(@BULK_TIMEOUT) do
        begin
          http_client.post(path, data, HEADERS.merge('Content-Type' => 'application/json'))
        rescue EOFError # Connection cut out. Just try a second time.
          http_client.post(path, data, HEADERS.merge('Content-Type' => 'application/json'))
        end
      end

      if response.code =~ /^2\d\d/
        (response.body && response.body != "") ? JSON.parse(response.body) : []
      else
        raise TowerDataApi::Error::Api, "Error Code #{response.code}: \"#{response.body}\""
      end
    end

    # Takes a url and returns a hash mapping attribute fields onto attributes
    # Note that an exception is raised in the case that
    # an HTTP response code other than 200 is sent back
    # The error code and error body are put in the exception's message
    def get_json_response(path)
      response = Timeout::timeout(Configuration.timeout) do
        begin
          http_client.get(path, HEADERS)
        rescue EOFError # Connection cut out. Just try a second time.
          http_client.get(path, HEADERS)
        end
      end

      if response.code =~ /^2\d\d/
        (response.body && response.body != "") ? JSON.parse(response.body) : {}
      elsif response.code == '400' 
        raise TowerDataApi::Error::BadRequest, "Bad request#{response.code}: \"#{response.body}\""
      else
        raise TowerDataApi::Error::Api, "Error Code #{response.code}: \"#{response.body}\""
      end
    end

    # Returns http connection to HOST on PORT
    def http_client
      unless defined?(@http_client)
        @http_client = Net::HTTP.new(HOST, PORT)
        @http_client.use_ssl = true
        @http_client.ca_file = Configuration.ca_file if Configuration.ca_file
        #@http_client.verify_mode = OpenSSL::SSL::VERIFY_PEER
        @http_client.start
      end
      @http_client
    end

    def bulk_path
      "#{api_path}#{BULK_PATH}?api_key=#{@api_key}"
    end

    def base_path
      "#{api_path}#{BASE_PATH}?api_key=#{@api_key}"
    end

    def api_path
      "/v#{API_VERSION}"
    end
  end
end
