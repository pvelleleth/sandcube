require "../src/cli/bundle"

include Sandcube::CLI
raise "Usage: package VERSION LAUNCHER API ADAPTER DEPS OUTPUT" unless ARGV.size == 6
version, launcher, api, adapter, deps, destination = ARGV
raise "Invalid version" unless version.matches?(/\A[0-9A-Za-z][0-9A-Za-z._-]{0,79}\z/)
entries = [] of Bundle::Entry
File.open(destination, "w", perm: 0o755) do |output|
  File.open(launcher) { |input| IO.copy(input, output) }
  {"sandcube-api" => api, "containerd-runtime" => adapter, "install-deps.sh" => deps}.each do |name, path|
    offset = output.pos
    File.open(path) { |input| IO.copy(input, output) }
    entries << Bundle::Entry.new(name, offset, output.pos - offset, Bundle.checksum(path))
  end
  manifest = Bundle::Manifest.new(version, entries).to_json
  output << manifest
  output.write_bytes(manifest.bytesize.to_u64, IO::ByteFormat::LittleEndian)
  output << Bundle::MAGIC
end
File.chmod(destination, 0o755)
