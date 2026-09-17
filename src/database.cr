require "sqlite3"
require "file_utils"

module Sandcube::Database
  def self.open(path : String) : DB::Database
    Dir.mkdir_p(File.dirname(path))
    db = DB.open("sqlite3://#{path}?max_pool_size=1")
    db.setup_connection do |conn|
      conn.exec("PRAGMA foreign_keys=ON")
      conn.exec("PRAGMA busy_timeout=5000")
      conn.exec("PRAGMA journal_mode=WAL")
      conn.exec("PRAGMA synchronous=FULL")
    end
    File.chmod(path, 0o600)
    db.transaction do |tx|
      {% for migration in %w(001_images 002_reliability 003_resources) %}
        {{ read_file("#{__DIR__}/../migrations/#{migration.id}.sql") }}.split(';').each do |sql|
          tx.connection.exec(sql) unless sql.strip.empty?
        end
      {% end %}
    end
    db
  rescue ex
    db.try(&.close)
    raise ex
  end
end
