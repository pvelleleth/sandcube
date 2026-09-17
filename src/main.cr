require "./service"
require "./environment"

Sandcube::Environment.load unless ENV["SANDCUBE_MANAGED"]? == "true"

Log.setup("*", :info, Log::IOBackend.new(STDOUT, formatter: Log::Formatter.new do |entry, io|
  io << {time: entry.timestamp.to_rfc3339, level: entry.severity.to_s.downcase,
         event: "application.log", message: entry.message, error: entry.exception.try(&.message)}.to_json
end))

runtime = Sandcube::ContainerdRuntime.new(ENV.fetch("SANDCUBE_RUNTIME_SOCKET", "/run/sandcube/runtime.sock"))
if ENV.has_key?("DATABASE_URL") && !ENV.has_key?("SANDCUBE_DATA_DIR")
  raise "Legacy database configuration: set SANDCUBE_DATA_DIR to a fresh directory and use a fresh runtime namespace after exporting or retiring old sandboxes"
end
data_dir = ENV.fetch("SANDCUBE_DATA_DIR", "/var/lib/sandcube/data")
Dir.mkdir_p(data_dir)
api_lock = File.open(File.join(data_dir, "api.lock"), "a", perm: 0o600)
api_lock.flock_exclusive(blocking: false)
database = Sandcube::Database.open(File.join(data_dir, "sandcube.db"))
store = database.try { |db| Sandcube::ImageStore.new(db) }
reliability = database.try { |db| Sandcube::Reliability.new(db, runtime, Sandcube::Capacity.from_env) }
images = (ENV.fetch("SANDCUBE_IMAGE_API_ENABLED", "true") == "true" ? store : nil).try do |db|
  Sandcube::ImageManager.new(db,
    Sandcube::BuildKitImageBuilder.new(runtime, ENV.fetch("SANDCUBE_BUILDKIT_ADDRESS", "unix:///run/buildkit/buildkitd.sock"), ENV.fetch("SANDCUBE_BUILDCTL", "buildctl")),
    ENV.fetch("SANDCUBE_BUILD_ROOT", "/var/lib/sandcube/builds"))
end
service = Sandcube::Service.new(
  runtime,
  images, store, reliability
)
if coordinator = reliability
  coordinator.reconcile
  spawn do
    loop do
      sleep ENV.fetch("SANDCUBE_RECONCILE_SECONDS", "15").to_i.clamp(1, 3600).seconds
      coordinator.reconcile
    end
  end
end
server = HTTP::Server.new { |context| service.call(context) }
address = server.bind_tcp(ENV.fetch("SANDCUBE_HOST", "127.0.0.1"), ENV.fetch("SANDCUBE_PORT", "7432").to_i)
Signal::INT.trap { server.close }
Signal::TERM.trap { server.close }
puts({event: "api.listening", address: address.to_s}.to_json)
server.listen
database.close
api_lock.close
