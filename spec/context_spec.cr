require "spec"
require "../src/images/context"
require "uuid"

# Real ustar bytes, compressed with Crystal's gzip writer.
def archive_entry(name = "file", content = "hello", kind = '0', size : Int64? = nil)
  header = Bytes.new(512, 0_u8)
  header[0, name.bytesize].copy_from(name.to_slice)
  {100 => "0000755\0", 124 => "%011o\0" % (size || content.bytesize), 148 => "        ", 257 => "ustar\0"}.each do |offset, text|
    header[offset, text.bytesize].copy_from(text.to_slice)
  end
  header[156] = kind.ord.to_u8
  checksum = "%06o\0 " % header.sum(&.to_i64)
  header[148, 8].copy_from(checksum.to_slice)
  io = IO::Memory.new
  io.write(header)
  io << content
  io.write(Bytes.new((512 - content.bytesize % 512) % 512))
  io.to_s
end

def gzip_tar(raw)
  io = IO::Memory.new
  Compress::Gzip::Writer.open(io) { |gz| gz << raw; gz.write(Bytes.new(1024)) }
  io.to_slice
end

def with_context(&)
  path = File.join(Dir.tempdir, "sandcube-context-spec-#{UUID.random}")
  Dir.mkdir(path, 0o700)
  begin
    yield path
  ensure
    FileUtils.rm_rf(path)
  end
end

describe Sandcube::BuildContext do
  it "extracts nested files and preserves executable permissions" do
    with_context do |dir|
      Sandcube::BuildContext.extract(gzip_tar(archive_entry("./nested/tool")), dir)
      File.read("#{dir}/nested/tool").should eq("hello")
      (File.info("#{dir}/nested/tool").permissions.value & 0o777).should eq(0o755)
    end
  end
  ["../escape", "/tmp/escape", "a/../../escape", "a\\escape"].each do |path|
    it "rejects unsafe path #{path}" do
      with_context do |dir|
        expect_raises(ArgumentError, "Unsafe archive path") { Sandcube::BuildContext.extract(gzip_tar(archive_entry(path)), dir) }
        Dir.children(dir).should be_empty
      end
    end
  end
  ['1', '2', '3', '4', '6', 'x', 'g', 'L'].each do |kind|
    it "rejects archive type #{kind}" do
      with_context do |dir|
        expect_raises(ArgumentError) { Sandcube::BuildContext.extract(gzip_tar(archive_entry(kind: kind)), dir) }
      end
    end
  end
  it "rejects duplicate entries before overwriting" do
    with_context do |dir|
      expect_raises(ArgumentError, "Duplicate") { Sandcube::BuildContext.extract(gzip_tar(archive_entry + archive_entry(content: "changed")), dir) }
      File.read("#{dir}/file").should eq("hello")
    end
  end
  it "rejects expanded size bombs without writing their data" do
    with_context do |dir|
      expect_raises(ArgumentError, "expanded size") { Sandcube::BuildContext.extract(gzip_tar(archive_entry(size: 300_i64 * 1024 * 1024)), dir) }
      Dir.children(dir).should be_empty
    end
  end
  it "rejects archives with excessive entry counts" do
    with_context do |dir|
      data = gzip_tar(archive_entry(".", "", '5') * 10001)
      expect_raises(ArgumentError, "Too many archive entries") { Sandcube::BuildContext.extract(data, dir) }
    end
  end
  it "validates the gzip trailer even after the tar terminator" do
    with_context do |dir|
      data = gzip_tar(archive_entry).dup
      data[data.size - 8] ^= 1_u8
      expect_raises(ArgumentError) { Sandcube::BuildContext.extract(data, dir) }
    end
  end
  it "rejects corrupt headers, truncated archives, and invalid gzip" do
    with_context do |dir|
      ["garbage".to_slice, gzip_tar("short"), gzip_tar(archive_entry.sub("file", "evil"))].each do |data|
        expect_raises(ArgumentError) { Sandcube::BuildContext.extract(data, dir) }
      end
    end
  end
end
