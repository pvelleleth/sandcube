require "json"
require "http/client"
require "socket"

module Sandcube
  class RuntimeError < Exception
    getter status : Int32
    getter body : String

    def initialize(@status, @body)
      super("Runtime request failed (#{status})")
    end
  end

  abstract class Runtime
    abstract def request(method : String, path : String, body : String? = nil) : JSON::Any
  end

  class ContainerdRuntime < Runtime
    def initialize(@socket_path : String)
    end

    def request(method : String, path : String, body : String? = nil) : JSON::Any
      socket = UNIXSocket.new(@socket_path)
      client = HTTP::Client.new(socket)
      client.read_timeout = 3630.seconds
      begin
        response = client.exec(method, path, HTTP::Headers{"Content-Type" => "application/json"}, body)
        raise RuntimeError.new(response.status_code, response.body) unless response.success?
        JSON.parse(response.body)
      ensure
        client.close
      end
    end
  end
end
