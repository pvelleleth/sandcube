require "./service"

runtime = Sandcube::ContainerdRuntime.new(ENV.fetch("SANDCUBE_RUNTIME_SOCKET", "/run/sandcube/runtime.sock"))
store = ENV["DATABASE_URL"]?.try { |url| Sandcube::ImageStore.new(DB.open(url)) }
images = store.try do |db|
  Sandcube::ImageManager.new(db,
    Sandcube::BuildKitImageBuilder.new(runtime, ENV.fetch("SANDCUBE_BUILDKIT_ADDRESS", "unix:///run/buildkit/buildkitd.sock"), ENV.fetch("SANDCUBE_BUILDCTL", "buildctl")),
    ENV.fetch("SANDCUBE_BUILD_ROOT", "/var/lib/sandcube/builds"))
end
service = Sandcube::Service.new(
  runtime,
  ENV.fetch("SANDCUBE_API_KEY"), images, store
)
server = HTTP::Server.new { |context| service.call(context) }
address = server.bind_tcp(ENV.fetch("SANDCUBE_HOST", "127.0.0.1"), ENV.fetch("SANDCUBE_PORT", "8080").to_i)
Signal::INT.trap { server.close }
Signal::TERM.trap { server.close }
puts "Sandcube listening on #{address}"
server.listen
