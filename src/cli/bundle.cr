require "digest/sha256"
require "json"
require "./config"

module Sandcube::CLI
  class Bundle
    MAGIC = "SANDCUBE_BUNDLE_V1\n"
    NAMES = %w(sandcube-api containerd-runtime install-deps.sh)
    record Entry, name : String, offset : Int64, size : Int64, sha256 : String do
      include JSON::Serializable
    end
    record Manifest, version : String, entries : Array(Entry) do
      include JSON::Serializable
    end
    getter manifest : Manifest

    def self.checksum(path : String) : String
      File.open(path) { |file| Digest::SHA256.new.update(file).hexfinal }
    end

    def initialize(@path : String = Process.executable_path.not_nil!)
      @manifest = File.open(@path) do |file|
        raise "No release payload; use make build" if file.size < MAGIC.bytesize + 8
        file.seek(-MAGIC.bytesize, IO::Seek::End)
        raise "No release payload; use make build" unless file.gets_to_end == MAGIC
        file.seek(-MAGIC.bytesize - 8, IO::Seek::End)
        length = file.read_bytes(UInt64, IO::ByteFormat::LittleEndian)
        raise "Invalid bundle manifest size" unless 0 < length <= 65536 && length < file.pos - 8
        start = file.pos - 8 - length.to_i64
        file.seek(start)
        value = Manifest.from_json(file.read_string(length.to_i))
        raise "Invalid release version" unless value.version.matches?(/\A[0-9A-Za-z][0-9A-Za-z._-]{0,79}\z/)
        raise "Invalid payload entries" unless value.entries.map(&.name).sort == NAMES.sort
        previous = 0_i64
        value.entries.each do |entry|
          raise "Invalid payload bounds" unless entry.offset >= previous && entry.size > 0 && entry.offset <= start && entry.size <= start - entry.offset
          raise "Invalid payload checksum" unless entry.sha256.matches?(/\A[0-9a-f]{64}\z/)
          previous = entry.offset + entry.size
        end
        value
      end
    end

    def extract(data_dir : String) : String
      base = File.join(data_dir, "bin")
      CLI.private_dir(base)
      # The content ID prevents a rebuilt version from overwriting a running adapter's logger.
      identity = Digest::SHA256.hexdigest(@manifest.to_json)[0, 16]
      dir = File.join(base, "#{@manifest.version}-#{identity}")
      CLI.private_dir(dir)
      @manifest.entries.each do |entry|
        destination = File.join(dir, entry.name)
        if File.exists?(destination) || File.symlink?(destination)
          info = File.info(destination, follow_symlinks: false)
          raise "Unsafe extracted payload: #{destination}" unless info.file? && info.owner_id == SandcubePosix.geteuid.to_s && info.permissions.value & 0o7777 == 0o700
          raise "Checksum mismatch: #{destination}" unless Bundle.checksum(destination) == entry.sha256
          next
        end
        target = File.tempfile(".payload-", dir: dir)
        begin
          File.open(@path) do |source|
            source.seek(entry.offset)
            copied = IO.copy(source, target, entry.size)
            raise "Truncated payload" unless copied == entry.size
            target.flush
            target.fsync
          end
          raise "Checksum mismatch for #{entry.name}" unless Bundle.checksum(target.path) == entry.sha256
          File.chmod(target.path, 0o700)
          File.link(target.path, destination)
        ensure
          target.close
          target.delete
        end
      end
      dir
    end
  end
end
