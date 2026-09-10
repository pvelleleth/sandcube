require "base64"

module Sandcube
  # Public transfer semantics belong here; the adapter only mounts snapshots and
  # performs confined filesystem primitives. Binary data uses base64 on the UDS.
  module Files
    MAX_TRANSFER = 16 * 1024 * 1024

    def self.call(runtime : Runtime, context : HTTP::Server::Context, id : String, content : Bool)
      request = context.request
      path = request.query_params["path"]? || "/"
      raise ImageError.new(400, "INVALID_PATH", "Invalid sandbox path") if path.includes?('\0') || path.split('/').includes?("..") || path.bytesize > 4096
      operation = case {request.method, content}
                  when {"GET", true}     then "read"
                  when {"PUT", true}     then "write"
                  when {"GET", false}    then "list"
                  when {"POST", false}   then "mkdir"
                  when {"DELETE", false} then "delete"
                  else                        raise ArgumentError.new("Unsupported file operation")
                  end
      mode = request.query_params["mode"]?.try(&.to_i(8))
      raise ArgumentError.new("mode must be octal 0000–0777") if mode && !(0..0o777).includes?(mode)
      data = ""
      if operation == "write"
        buffer = IO::Memory.new
        if body = request.body
          IO.copy(body, buffer, MAX_TRANSFER + 1)
        end
        if buffer.size > MAX_TRANSFER
          raise ImageError.new(413, "LIMIT_EXCEEDED", "Upload exceeds 16 MiB")
        end
        data = Base64.strict_encode(buffer.to_slice)
      end
      result = runtime.request("POST", "/containers/#{id}/files", {operation: operation, path: path, content: data, mode: mode}.to_json)
      if operation == "read"
        context.response.content_type = "application/octet-stream"
        context.response.headers["Content-Disposition"] = "attachment"
        context.response.write(Base64.decode(result["content"].as_s))
      else
        context.response.print(result.to_json)
      end
    end
  end
end
