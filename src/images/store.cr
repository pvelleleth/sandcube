require "../database"

module Sandcube
  class ImageError < Exception
    getter status : Int32
    getter code : String

    def initialize(@status, @code, message)
      super(message)
    end
  end

  class ImageStore
    def initialize(@db : DB::Database)
    end

    def get(id : String) : JSON::Any
      raw = @db.query_one?("SELECT json_object('id',id,'name',name,'status',status,'oci_reference',oci_reference,'oci_digest',oci_digest,'dockerfile',dockerfile,'created_at',created_at,'updated_at',updated_at,'error_message',error_message) FROM images WHERE id=?1", id, as: String)
      raise ImageError.new(404, "IMAGE_NOT_FOUND", "Image #{id} does not exist") unless raw
      JSON.parse(raw)
    end

    def create(id, name, dockerfile)
      @db.exec("INSERT INTO images(id,name,status,oci_reference,dockerfile) VALUES(?1,?2,'BUILDING',?3,?4)", id, name, reference(id), dockerfile)
      get(id)
    end

    def reference(id)
      "sandcube.local/images/#{id}:latest"
    end

    def ready(id, digest)
      @db.exec("UPDATE images SET status='READY',oci_digest=?2,error_message=NULL,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id=?1 AND status='BUILDING'", id, digest)
    end

    def failed(id, message)
      @db.exec("UPDATE images SET status='ERROR',error_message=?2,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id=?1", id, message)
    end

    def reserve(id, sandbox_id) : String
      reference = ""
      @db.transaction do |tx|
        conn = tx.connection
        row = conn.query_one?("SELECT status,oci_reference FROM images WHERE id=?1", id, as: {String, String})
        raise ImageError.new(404, "IMAGE_NOT_FOUND", "Image #{id} does not exist") unless row
        raise ImageError.new(409, "IMAGE_NOT_READY", "Image #{id} is #{row[0]}") unless row[0] == "READY"
        conn.exec("INSERT INTO sandbox_images(sandbox_id,image_id) VALUES(?1,?2)", sandbox_id, id)
        reference = row[1]
      end
      reference
    end

    def release(sandbox_id)
      @db.exec("DELETE FROM sandbox_images WHERE sandbox_id=?1", sandbox_id)
    end

    def image_id(sandbox_id) : String?
      @db.query_one?("SELECT image_id FROM sandbox_images WHERE sandbox_id=?1", sandbox_id, as: String)
    end

    def begin_delete(id) : JSON::Any
      @db.transaction do |tx|
        conn = tx.connection
        state = conn.query_one?("SELECT status FROM images WHERE id=?1", id, as: String)
        raise ImageError.new(404, "IMAGE_NOT_FOUND", "Image #{id} does not exist") unless state
        raise ImageError.new(409, "IMAGE_BUILDING", "Cannot delete an active build") if state == "BUILDING"
        count = conn.query_one("SELECT count(*) FROM sandbox_images WHERE image_id=?1", id, as: Int64)
        raise ImageError.new(409, "IMAGE_IN_USE", "Image is referenced by sandboxes") if count > 0
        conn.exec("UPDATE images SET status='DELETING',updated_at=strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id=?1 AND status != 'DELETED'", id)
      end
      get(id)
    end

    def deleted(id)
      @db.exec("UPDATE images SET status='DELETED',updated_at=strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),error_message=NULL WHERE id=?1", id)
      get(id)
    end

    def interrupted_builds
      @db.exec("UPDATE images SET status='ERROR',error_message='Build interrupted by service restart',updated_at=strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE status='BUILDING'")
    end
  end
end
