require "http/formdata"
require "base64"
require "./store"
require "./context"

module Sandcube
  class BuildLog < IO
    getter text = IO::Memory.new

    def read(slice : Bytes) : Int32
      raise IO::Error.new("write only")
    end

    def write(slice : Bytes) : Nil
      left = 65536 - @text.size
      @text.write(slice[0, Math.min(left, slice.size)]) if left > 0
    end
  end

  abstract class ImageBuilder
    abstract def build(directory : String, reference : String, args : Hash(String, String)) : JSON::Any
    abstract def delete(reference : String) : Nil
  end

  class BuildKitImageBuilder < ImageBuilder
    def initialize(@runtime : Runtime, @address = "unix:///run/buildkit/buildkitd.sock", @binary = "buildctl", @timeout = 1800)
    end

    def build(directory : String, reference : String, args : Hash(String, String)) : JSON::Any
      argv = ["--signal=TERM", "--kill-after=10s", @timeout.to_s, @binary, "--addr", @address,
              "build", "--frontend", "dockerfile.v0", "--local", "context=#{directory}/context",
              "--local", "dockerfile=#{directory}/dockerfile", "--output", "type=oci,name=#{reference},dest=#{directory}/image.tar",
              "--progress", "plain"]
      args.each { |key, value| argv.concat(["--opt", "build-arg:#{key}=#{value}"]) }
      output = BuildLog.new
      status = Process.run("timeout", argv, env: {"PATH" => ENV.fetch("PATH", "/usr/bin:/bin"), "HOME" => directory}, clear_env: true, output: output, error: output)
      raise ImageError.new(500, "IMAGE_BUILD_FAILED", "BuildKit exited #{status.exit_code}: #{output.text}") unless status.success?
      @runtime.request("POST", "/images/import", {reference: reference, path: "#{directory}/image.tar"}.to_json)
    end

    def delete(reference : String) : Nil
      @runtime.request("POST", "/images/delete", {reference: reference}.to_json)
    end
  end

  class ImageManager
    MAX_UPLOAD = 48 * 1024 * 1024
    @build_lock = Mutex.new
    @pending = 0
    @directory_lock : File

    def initialize(@store : ImageStore, @builder : ImageBuilder, @root : String)
      Dir.mkdir_p(@root)
      File.chmod(@root, 0o700)
      @directory_lock = File.open(File.join(@root, ".lock"), "w")
      @directory_lock.flock_exclusive(blocking: false)
      # Only one service owns this directory/database. Interrupted builds are not resumed.
      Dir.glob(File.join(@root, "build-*")).each { |path| FileUtils.rm_rf(path) }
      @store.interrupted_builds
    end

    def submit(request : HTTP::Request) : JSON::Any
      raise ImageError.new(429, "BUILD_QUEUE_FULL", "At most eight builds may be pending") if @pending >= 8
      body = request.body || raise ArgumentError.new("Image body is required")
      buffer = IO::Memory.new
      IO.copy(body, buffer, MAX_UPLOAD + 1)
      raise ArgumentError.new("Image request exceeds 48 MiB") if buffer.size > MAX_UPLOAD
      dockerfile = ""
      name : String? = nil
      args = {} of String => String
      archive : Bytes? = nil
      if request.headers["Content-Type"]?.try(&.starts_with?("multipart/form-data"))
        bounded = HTTP::Request.new("POST", "/", request.headers, buffer.to_s)
        seen = Set(String).new
        HTTP::FormData.parse(bounded) do |part|
          raise ArgumentError.new("Duplicate image field") unless seen.add?(part.name)
          case part.name
          when "dockerfile" then dockerfile = part.body.gets_to_end
          when "name"       then name = part.body.gets_to_end
          when "build_args" then args = parse_args(JSON.parse(part.body.gets_to_end))
          when "context"    then archive = part.body.gets_to_end.to_slice.dup
          else                   raise ArgumentError.new("Unknown image field")
          end
        end
      else
        input = JSON.parse(buffer.to_s).as_h
        raise ArgumentError.new("Unknown image field") unless input.keys.all? { |key| {"dockerfile", "name", "build_args", "context_tar_gz"}.includes?(key) }
        dockerfile = input["dockerfile"].as_s
        name = input["name"]?.try(&.as_s)
        args = parse_args(input["build_args"]) if input.has_key?("build_args")
        archive = Base64.decode(input["context_tar_gz"].as_s) if input.has_key?("context_tar_gz")
      end
      raise ArgumentError.new("Dockerfile must contain 1–65536 bytes") if dockerfile.strip.empty? || dockerfile.bytesize > 65536
      raise ArgumentError.new("Image name exceeds 200 bytes") if name && name.bytesize > 200
      id = "img_#{UUID.random.to_s.gsub("-", "")}"
      directory = File.join(@root, "build-#{id}")
      raise ImageError.new(429, "BUILD_QUEUE_FULL", "At most eight builds may be pending") if @pending >= 8
      @pending += 1
      begin
        Dir.mkdir(directory, 0o700)
        Dir.mkdir(File.join(directory, "context"))
        Dir.mkdir(File.join(directory, "dockerfile"))
        BuildContext.extract(archive, File.join(directory, "context")) if archive
        File.write(File.join(directory, "dockerfile", "Dockerfile"), dockerfile)
        result = @store.create(id, name, dockerfile)
      rescue ex
        @pending -= 1
        FileUtils.rm_rf(directory)
        raise ex
      end
      spawn do
        @build_lock.synchronize do
          begin
            info = @builder.build(directory, @store.reference(id), args)
            @store.ready(id, info["oci_digest"].as_s)
          rescue ex
            # Import/unpack may have partially succeeded. Remove its managed reference.
            message = ex.message || "Image build failed"
            begin
              @builder.delete(@store.reference(id))
            rescue cleanup
              message += "; image cleanup failed: #{cleanup.message}"
            end
            begin
              @store.failed(id, message)
            rescue metadata_error
              Log.error(exception: metadata_error) { "Unable to record failed build #{id}" }
            end
            Log.warn { "Image build failed: #{id}" }
          ensure
            @pending -= 1
            FileUtils.rm_rf(directory)
          end
        end
      end
      result
    rescue ex : Base64::Error | HTTP::FormData::Error | MIME::Multipart::Error
      raise ArgumentError.new("Invalid image upload: #{ex.message}")
    end

    private def parse_args(value : JSON::Any) : Hash(String, String)
      args = value.as_h.transform_values(&.as_s)
      raise ArgumentError.new("Too many build arguments") if args.size > 100
      args.each do |key, val|
        raise ArgumentError.new("Invalid build argument") unless key.matches?(/\A[A-Za-z_][A-Za-z0-9_]*\z/) && val.bytesize <= 8192 && !val.includes?('\0')
      end
      args
    end

    def get(id)
      @store.get(id)
    end

    def delete(id)
      row = @store.begin_delete(id)
      return row if row["status"].as_s == "DELETED"
      @builder.delete(row["oci_reference"].as_s)
      @store.deleted(id)
    end
  end
end
