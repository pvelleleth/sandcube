require "http/server"
require "uuid"
require "crypto/subtle"
require "log"
require "./runtime/runtime"
require "./images/builder"
require "./files/api"
require "./reliability"

module Sandcube
  class Service
    MAX_BODY = 64 * 1024
    @lifecycle_locks = Array(Mutex).new(256) { Mutex.new }

    def initialize(@runtime : Runtime, @api_key : String, @images : ImageManager? = nil, @image_store : ImageStore? = nil, @reliability : Reliability? = nil)
      raise ArgumentError.new("SANDCUBE_API_KEY must contain at least 32 bytes") if @api_key.bytesize < 32
    end

    def call(context : HTTP::Server::Context)
      started = Time.instant
      response = context.response
      response.content_type = "application/json"
      expected = "Bearer #{@api_key}"
      supplied = context.request.headers["Authorization"]? || ""
      unless Crypto::Subtle.constant_time_compare(supplied, expected)
        return error(context, 401, "UNAUTHORIZED", "A valid API key is required")
      end
      method = context.request.method
      path = context.request.path
      if reliability = @reliability
        if method == "GET" && path == "/metrics"
          response.content_type = "text/plain; version=0.0.4"
          response.print(reliability.metrics)
          return
        end
        lifecycle = method == "POST" && path == "/v1/sandboxes"
        if match = /^\/v1\/sandboxes\/sbx_[a-zA-Z0-9_-]{1,80}(?:\/(start|stop|restart))?$/.match(path)
          valid_method = match[1]? ? method == "POST" : {"GET", "DELETE"}.includes?(method)
          return error(context, 404, "NOT_FOUND", "Unknown route") unless valid_method
          lifecycle = true
        end
        if lifecycle
          value = if method == "GET"
                    reliability.inspect(path.split('/')[3])
                  else
                    body = path == "/v1/sandboxes" ? read_body(context) : nil
                    reliability.request(method, path, body, context.request.headers["Idempotency-Key"]?)
                  end
          response.status_code = 201 if method == "POST" && path == "/v1/sandboxes"
          response.print(value.to_json)
          return
        end
      end
      result = if method == "GET" && path == "/health"
                 @reliability.try(&.health)
                 @runtime.request("GET", "/health")
               elsif method == "POST" && path == "/v1/images"
                 manager = @images || raise ImageError.new(503, "IMAGES_UNAVAILABLE", "Image building is not configured")
                 value = manager.submit(context.request)
                 response.status_code = 202
                 value
               elsif match = /^\/v1\/images\/(img_[a-zA-Z0-9_-]{1,80})$/.match(path)
                 manager = @images || raise ImageError.new(503, "IMAGES_UNAVAILABLE", "Image building is not configured")
                 case method
                 when "GET"    then manager.get(match[1])
                 when "DELETE" then manager.delete(match[1])
                 else               return error(context, 404, "NOT_FOUND", "Unknown route")
                 end
               elsif match = /^\/v1\/sandboxes\/(sbx_[a-zA-Z0-9_-]{1,80})\/files(\/content)?$/.match(path)
                 Files.call(@runtime, context, match[1], !match[2]?.nil?)
                 return
               elsif match = /^\/v1\/sandboxes\/(sbx_[a-zA-Z0-9_-]{1,80})\/processes(?:\/(proc_[a-f0-9]{32})(?:\/(logs|kill))?)?$/.match(path)
                 suffix = path.sub("/v1/sandboxes/", "/containers/")
                 body = method == "POST" && match[2]?.nil? ? process_body(context, match[1]) : nil
                 value = @runtime.request(method, suffix, body)
                 response.status_code = 202 if method == "POST" && match[2]?.nil?
                 value
               elsif method == "POST" && path == "/v1/sandboxes"
                 create(context)
               elsif match = /^\/v1\/sandboxes\/(sbx_[a-zA-Z0-9_-]{1,80})(?:\/(start|stop|restart|exec))?$/.match(path)
                 id = match[1]
                 action = match[2]?
                 operation = -> do
                   if method == "GET" && action.nil?
                     with_image(@runtime.request("GET", "/containers/#{id}"), id)
                   elsif method == "DELETE" && action.nil?
                     value = @runtime.request("DELETE", "/containers/#{id}")
                     @image_store.try(&.release(id))
                     value
                   elsif method == "POST" && action == "restart"
                     @runtime.request("POST", "/containers/#{id}/stop")
                     @runtime.request("POST", "/containers/#{id}/start")
                   elsif method == "POST" && {"start", "stop", "exec"}.includes?(action)
                     body = action == "exec" ? process_body(context, id) : nil
                     @runtime.request("POST", "/containers/#{id}/#{action}", body)
                   else
                     raise ArgumentError.new("Unsupported sandbox operation")
                   end
                 end
                 if action == "exec"
                   operation.call
                 else
                   @lifecycle_locks[id.hash % 256].synchronize { operation.call }
                 end
               else
                 return error(context, 404, "NOT_FOUND", "Unknown route")
               end
      response.print(result.to_json)
    rescue ex : ImageError
      error(context, ex.status, ex.code, ex.message || ex.code)
    rescue ex : RuntimeError
      context.response.status_code = ex.status
      context.response.print(ex.body)
    rescue ex : JSON::ParseException | TypeCastError | ArgumentError | KeyError
      error(context, 400, "INVALID_REQUEST", ex.message || "Invalid request")
    rescue ex
      STDOUT.puts({level: "error", event: "api.error", message: ex.message}.to_json)
      error(context, 503, "RUNTIME_UNAVAILABLE", "Runtime operation unavailable")
    ensure
      STDOUT.puts({time: Time.utc.to_rfc3339, event: "api.request", method: context.request.method,
                   path: context.request.path, status: context.response.status_code,
                   duration_ms: started.try { |time| (Time.instant - time).total_milliseconds }}.to_json)
    end

    private def process_body(context, id) : String
      body = read_body(context)
      input = JSON.parse(body).as_h
      raise ArgumentError.new("request_id is internal") if input.has_key?("request_id")
      if key = context.request.headers["Idempotency-Key"]?
        raise ArgumentError.new("Invalid Idempotency-Key") if key.empty? || key.bytesize > 200
        digest = Digest::SHA256.hexdigest("#{id}\n#{context.request.path}\n#{key}")
        input["request_id"] = JSON::Any.new("proc_#{digest[0, 32]}")
        return input.to_json
      end
      body
    end

    private def read_body(context) : String
      body = context.request.body
      raise ArgumentError.new("JSON body is required") unless body
      buffer = IO::Memory.new
      IO.copy(body, buffer, MAX_BODY + 1)
      value = buffer.to_s
      raise ArgumentError.new("Request body exceeds 64 KiB") if value.bytesize > MAX_BODY
      value
    end

    private def create(context) : JSON::Any
      input = JSON.parse(read_body(context)).as_h
      allowed = {"image", "image_id", "command", "cpu", "memory_mb", "disk_mb", "pids"}
      raise ArgumentError.new("Unknown create field") unless input.keys.all? { |key| allowed.includes?(key) }
      raise ArgumentError.new("Provide exactly one of image or image_id") unless input.has_key?("image") != input.has_key?("image_id")
      command = input["command"].as_a.map(&.as_s)
      id = "sbx_#{UUID.random.to_s.gsub("-", "")}"
      image_id = input["image_id"]?.try(&.as_s)
      # Parse all fields before reserving an image reference.
      cpu = input["cpu"]?.try(&.as_i) || 1
      memory = input["memory_mb"]?.try(&.as_i) || 256
      disk = input["disk_mb"]?.try(&.as_i) || 1024
      pids = input["pids"]?.try(&.as_i) || 128
      image = if image_id
                store = @image_store || raise ImageError.new(503, "IMAGES_UNAVAILABLE", "Image metadata is not configured")
                store.reserve(image_id, id)
              else
                input["image"].as_s
              end
      config = {id: id, image: image, command: command, cpu: cpu, memory_mb: memory, disk_mb: disk, pids: pids}
      begin
        @runtime.request("POST", "/containers", config.to_json)
        result = @runtime.request("POST", "/containers/#{id}/start")
      rescue ex
        # Roll back a failed create/start instead of abandoning a writable snapshot.
        begin
          @runtime.request("DELETE", "/containers/#{id}")
          @image_store.try(&.release(id))
        rescue cleanup
          Log.error(exception: cleanup) { "Create rollback failed for #{id}" }
        end
        raise ex
      end
      context.response.status_code = 201
      with_image(result, id)
    end

    private def with_image(result : JSON::Any, id : String) : JSON::Any
      if image_id = @image_store.try(&.image_id(id))
        result.as_h["image_id"] = JSON::Any.new(image_id)
      end
      result
    end

    private def error(context, status, code, message)
      context.response.status_code = status
      context.response.print({error: {code: code, message: message}}.to_json)
    end
  end
end
