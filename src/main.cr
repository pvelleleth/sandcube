require "./service"

Log.setup("*", :info, Log::IOBackend.new(STDOUT, formatter: Log::Formatter.new do |entry, io|
  io << {time: entry.timestamp.to_rfc3339, level: entry.severity.to_s.downcase,
         event: "application.log", message: entry.message, error: entry.exception.try(&.message)}.to_json
end))

runtime = Sandcube::ContainerdRuntime.new(ENV.fetch("SANDCUBE_RUNTIME_SOCKET", "/run/sandcube/runtime.sock"))
database = ENV["DATABASE_URL"]?.try { |url| DB.open(url) }
store = database.try { |db| Sandcube::ImageStore.new(db) }
reliability = database.try { |db| Sandcube::Reliability.new(db, runtime) }
images = (ENV.fetch("SANDCUBE_IMAGE_API_ENABLED", "true") == "true" ? store : nil).try do |db|
  Sandcube::ImageManager.new(db,
    Sandcube::BuildKitImageBuilder.new(runtime, ENV.fetch("SANDCUBE_BUILDKIT_ADDRESS", "unix:///run/buildkit/buildkitd.sock"), ENV.fetch("SANDCUBE_BUILDCTL", "buildctl")),
    ENV.fetch("SANDCUBE_BUILD_ROOT", "/var/lib/sandcube/builds"))
end
service = Sandcube::Service.new(
  runtime,
  ENV.fetch("SANDCUBE_API_KEY"), images, store, reliability
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
address = server.bind_tcp(ENV.fetch("SANDCUBE_HOST", "127.0.0.1"), ENV.fetch("SANDCUBE_PORT", "8080").to_i)
Signal::INT.trap { server.close }
Signal::TERM.trap { server.close }
puts({event: "api.listening", address: address.to_s}.to_json)
server.listen
