package main

import (
	"context"
	"github.com/containerd/errdefs"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type fakeImages struct {
	fakeBackend
	ref  string
	path string
}

func (f *fakeImages) ImportImage(_ context.Context, req ImageRequest) (ImageInfo, error) {
	f.called++
	f.ref = req.Reference
	f.path = req.Path
	return ImageInfo{Reference: req.Reference, Digest: "sha256:abc"}, f.err
}
func (f *fakeImages) InspectImage(_ context.Context, ref string) (ImageInfo, error) {
	f.called++
	f.ref = ref
	return ImageInfo{Reference: ref, Digest: "sha256:abc"}, f.err
}
func (f *fakeImages) DeleteImage(_ context.Context, ref string) error {
	f.called++
	f.ref = ref
	return f.err
}
func TestImageRoutes(t *testing.T) {
	for _, action := range []string{"import", "inspect", "delete"} {
		f := &fakeImages{}
		w := httptest.NewRecorder()
		(&server{backend: f}).ServeHTTP(w, httptest.NewRequest("POST", "/images/"+action, strings.NewReader(`{"reference":"sandcube.local/images/img_test:latest","path":"/build/image.tar"}`)))
		if w.Code != 200 || f.called != 1 || f.ref != "sandcube.local/images/img_test:latest" {
			t.Fatal(w.Code, w.Body.String(), f)
		}
	}
}
func TestRejectUnmanagedImageRequests(t *testing.T) {
	for _, body := range []string{`{}`, `{"reference":"docker.io/library/busybox:latest"}`, `{"reference":"sandcube.local/images/img_test:latest","privileged":true}`, `{"reference":"sandcube.local/images/img_../host:latest"}`} {
		f := &fakeImages{}
		w := httptest.NewRecorder()
		(&server{backend: f}).ServeHTTP(w, httptest.NewRequest("POST", "/images/delete", strings.NewReader(body)))
		if w.Code != 400 || f.called != 0 {
			t.Fatal(w.Code, w.Body.String())
		}
	}
}
func TestReferencedImageError(t *testing.T) {
	f := &fakeImages{fakeBackend: fakeBackend{err: errdefs.ErrFailedPrecondition}}
	w := httptest.NewRecorder()
	(&server{backend: f}).ServeHTTP(w, httptest.NewRequest("POST", "/images/delete", strings.NewReader(`{"reference":"sandcube.local/images/img_test:latest"}`)))
	if w.Code != 409 || !strings.Contains(w.Body.String(), "IMAGE_IN_USE") {
		t.Fatal(w.Code, w.Body.String())
	}
}

func TestImportRejectsArchivesOutsideBuildRoot(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	if err := os.WriteFile(filepath.Join(outside, "image.tar"), []byte("not an image"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "escape")); err != nil {
		t.Fatal(err)
	}
	r := &Runtime{buildRoot: root, namespace: "test"}
	for _, path := range []string{filepath.Join(outside, "image.tar"), filepath.Join(root, "escape", "image.tar")} {
		_, err := r.ImportImage(context.Background(), ImageRequest{Reference: "sandcube.local/images/img_test:latest", Path: path})
		if err == nil || !strings.Contains(err.Error(), "inside build root") {
			t.Fatalf("path %s: %v", path, err)
		}
	}
}
