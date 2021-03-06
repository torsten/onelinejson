# encoding: utf-8
require "onelinejson/version"
require 'json'
require 'lograge'

require 'active_support/core_ext/class/attribute'
require 'active_support/log_subscriber'

module Onelinejson
  REJECTED_HEADERS = [
    /^HTTP_CACHE_.+/,
    /^HTTP_CONNECTION$/,
    /^HTTP_VERSION$/,
    /^HTTP_PRAGMA$/,
    /^HTTP_ACCEPT_LANGUAGE$/,
    /^HTTP_REFERER$/,
    /^HTTP_COOKIE$/,
    /^HTTP_AUTHORIZATION$/,
    /.*HIDDEN.*/,
  ]
  ELIP = "\xe2\x80\xa6"
  LOG_MAX_LENGTH = 1900

  def self.trim_values(hash, trim_to)
    Hash[hash.map do |k, v|
      if v.is_a? String
        trimmed = if v.size > trim_to
          v[0, trim_to] + ELIP
        else
          v
        end
        [k, trimmed]
      else
        [k, v]
      end
    end]
  end

  def self.enforce_max_json_length(hash)
    return hash if JSON.dump(hash).size <= LOG_MAX_LENGTH

    deleted = hash[:request].delete(:params) || hash[:request].delete(:headers)
    if deleted
      enforce_max_json_length(hash)
    else
      hash
    end
  end

  module AppControllerMethods
    def append_info_to_payload(payload)
      super
      headers = if request.headers.respond_to?(:env)
        request.headers.env
      elsif request.headers.respond_to?(:to_hash)
        request.headers.to_hash
      end.select do |k, v|
        k =~ /^HTTP_/ && !REJECTED_HEADERS.any? {|regex| k =~ regex}
      end
      parameters = params.reject do |k,v|
        k == 'controller' ||
          k == 'action' ||
          v.is_a?(ActionDispatch::Http::UploadedFile) ||
          v.is_a?(Hash)
      end

      payload[:request] = {
        params: Onelinejson.trim_values(parameters, 128),
        headers: headers,
        ip: request.ip,
        uuid: request.env['action_dispatch.request_id'],
        controller: self.class.name,
        action: action_name,
        date: Time.now.utc.iso8601,
      }
      u_id = @current_user_id || (@current_user && @current_user.id)
      if u_id.present?
        payload[:request][:user_id] = u_id.to_i
      end
    end
  end

  class Railtie < Rails::Railtie
    config.log_tags = nil
    config.lograge = ActiveSupport::OrderedOptions.new
    config.lograge.formatter = ::Lograge::Formatters::Json.new
    config.lograge.enabled = true
    config.lograge.before_format = lambda do |data, payload|
      request = data.select{ |k,_|
        [:method, :path, :format].include?(k)
      }.merge(payload[:request])
      response = data.select{ |k,_|
        [:status, :duration, :view, :view_runtime].include?(k)
      }
      Onelinejson.enforce_max_json_length(
        {
          debug_info: payload[:debug_info] || {},
          request: request,
          response: response,
        })
    end

    ActiveSupport.on_load(:action_controller) do
      include AppControllerMethods
    end
  end
end
