require "compress/gzip"
require "file_utils"
require "set"

module Sandcube
  # Deliberately limited to regular files/directories in POSIX ustar archives.
  # Links, devices and extension headers cannot change extraction semantics.
  module BuildContext
    MAX_EXPANDED = 256_i64 * 1024 * 1024
    MAX_ENTRIES  = 10000

    def self.extract(data : Bytes, destination : String)
      Compress::Gzip::Reader.open(IO::Memory.new(data)) do |io|
        header = Bytes.new(512)
        seen = Set(String).new
        total = 0_i64
        entries = 0
        loop do
          io.read_fully(header)
          if header.all?(&.zero?)
            io.read_fully(header)
            raise ArgumentError.new("Invalid tar terminator") unless header.all?(&.zero?)
            # Consume the gzip trailer (CRC validation) and bounded zero padding.
            padding = Bytes.new(4096)
            while (n = io.read(padding)) > 0
              total += n
              raise ArgumentError.new("Invalid archive padding") unless padding[0, n].all?(&.zero?) && total <= MAX_EXPANDED
            end
            break
          end
          entries += 1
          raise ArgumentError.new("Too many archive entries") if entries > MAX_ENTRIES
          checksum = number(header[148, 8])
          sum = header.each_with_index.sum { |b, i| (148...156).includes?(i) ? 32_i64 : b.to_i64 }
          raise ArgumentError.new("Invalid tar checksum") unless sum == checksum
          name = field(header[0, 100])
          prefix = field(header[345, 155])
          name = "#{prefix}/#{name}" unless prefix.empty?
          raise ArgumentError.new("Unsafe archive path") if name.starts_with?("/") || name.includes?('\\') || name.split('/').includes?("..")
          parts = name.split('/').reject { |p| p.empty? || p == "." }
          kind = header[156]
          raise ArgumentError.new("Only regular files and directories are allowed") unless {0_u8, 48_u8, 53_u8}.includes?(kind)
          size = number(header[124, 12])
          total += size + 512 + (512 - size % 512) % 512
          raise ArgumentError.new("Build context exceeds expanded size limit") if total > MAX_EXPANDED
          raise ArgumentError.new("Directory has data") if kind == 53 && size != 0
          if parts.empty?
            raise ArgumentError.new("Empty file path") unless kind == 53
            next
          end
          relative = parts.join('/')
          raise ArgumentError.new("Duplicate archive path") unless seen.add?(relative)
          path = File.join(destination, relative)
          if kind == 53
            Dir.mkdir_p(path)
          else
            Dir.mkdir_p(File.dirname(path))
            File.open(path, "w", perm: 0o600) do |file|
              copied = IO.copy(io, file, size)
              raise ArgumentError.new("Truncated archive file") unless copied == size
            end
            File.chmod(path, (number(header[100, 8]) & 0o777).to_i)
          end
          skip = (512 - size % 512) % 512
          io.read_fully(Bytes.new(skip.to_i)) if skip > 0
        end
      end
    rescue ex : IO::Error | Compress::Gzip::Error | File::Error
      raise ArgumentError.new("Invalid build context: #{ex.message}")
    end

    private def self.field(bytes)
      String.new(bytes).split('\0', 2)[0]
    end

    private def self.number(bytes) : Int64
      value = field(bytes).strip
      return 0_i64 if value.empty?
      raise ArgumentError.new("Invalid tar numeric field") unless value.matches?(/\A[0-7]+\z/)
      value.to_i64(8)
    end
  end
end
