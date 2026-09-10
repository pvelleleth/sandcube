package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	containerd "github.com/containerd/containerd/v2/client"
	"github.com/containerd/containerd/v2/core/images"
	"github.com/containerd/errdefs"
)

var managedReference = regexp.MustCompile(`^sandcube\.local/images/img_[a-zA-Z0-9_-]{1,80}:latest$`)

type ImageRequest struct {
	Reference string `json:"reference"`
	Path      string `json:"path,omitempty"`
}
type ImageInfo struct {
	Reference string `json:"oci_reference"`
	Digest    string `json:"oci_digest"`
}
type ImageBackend interface {
	ImportImage(context.Context, ImageRequest) (ImageInfo, error)
	InspectImage(context.Context, string) (ImageInfo, error)
	DeleteImage(context.Context, string) error
}

func (r *Runtime) ImportImage(ctx context.Context, req ImageRequest) (result ImageInfo, err error) {
	r.imageMu.Lock()
	defer r.imageMu.Unlock()
	ctx = r.ctx(ctx)
	root, err := filepath.EvalSymlinks(r.buildRoot)
	if err != nil {
		return result, err
	}
	path, err := filepath.EvalSymlinks(req.Path)
	if err != nil {
		return result, err
	}
	relative, err := filepath.Rel(root, path)
	if err != nil || strings.HasPrefix(relative, "../") || filepath.Base(path) != "image.tar" || relative == "image.tar" {
		return result, fmt.Errorf("image archive must be inside build root")
	}
	f, err := os.Open(path)
	if err != nil {
		return result, err
	}
	defer f.Close()
	stat, err := f.Stat()
	if err != nil {
		return result, err
	}
	if !stat.Mode().IsRegular() {
		return result, fmt.Errorf("image archive must be a regular file")
	}
	if _, e := r.client.GetImage(ctx, req.Reference); e == nil {
		return result, errdefs.ErrAlreadyExists
	} else if !errdefs.IsNotFound(e) {
		return result, e
	}
	// Keep content alive through import AND unpack, and release on every outcome.
	ctx, done, err := r.client.WithLease(ctx)
	if err != nil {
		return result, err
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(r.ctx(context.Background()), 30*time.Second)
		defer cancel()
		if err != nil {
			_ = r.client.ImageService().Delete(cleanup, req.Reference)
		}
		_ = done(cleanup)
	}()
	_, err = r.client.Import(ctx, f,
		containerd.WithImageRefTranslator(func(string) string { return "" }),
		containerd.WithIndexName(req.Reference),
		containerd.WithImageLabels(map[string]string{ownerLabel: "true"}))
	if err != nil {
		return result, err
	}
	img, err := r.client.GetImage(ctx, req.Reference)
	if err != nil {
		return result, err
	}
	if err = img.Unpack(ctx, "overlayfs"); err != nil {
		return result, err
	}
	return ImageInfo{Reference: img.Name(), Digest: img.Target().Digest.String()}, nil
}
func (r *Runtime) InspectImage(ctx context.Context, ref string) (ImageInfo, error) {
	ctx = r.ctx(ctx)
	img, err := r.client.GetImage(ctx, ref)
	if err != nil {
		return ImageInfo{}, err
	}
	if img.Labels()[ownerLabel] != "true" {
		return ImageInfo{}, errdefs.ErrNotFound
	}
	return ImageInfo{Reference: img.Name(), Digest: img.Target().Digest.String()}, nil
}
func (r *Runtime) DeleteImage(ctx context.Context, ref string) error {
	r.imageMu.Lock()
	defer r.imageMu.Unlock()
	ctx = r.ctx(ctx)
	if _, err := r.InspectImage(ctx, ref); err != nil {
		if errdefs.IsNotFound(err) {
			return nil
		}
		return err
	}
	containers, err := r.client.Containers(ctx)
	if err != nil {
		return err
	}
	for _, c := range containers {
		info, err := c.Info(ctx)
		if err != nil {
			return err
		}
		if info.Image == ref {
			return fmt.Errorf("image is referenced by container %s: %w", c.ID(), errdefs.ErrFailedPrecondition)
		}
	}
	// containerd GC retains shared content/snapshots until their final reference disappears.
	return r.client.ImageService().Delete(ctx, ref, images.SynchronousDelete())
}
