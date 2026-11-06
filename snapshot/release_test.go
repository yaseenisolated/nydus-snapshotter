/*
 * Copyright (c) 2026. Nydus Developers. All rights reserved.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

package snapshot

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/containerd/containerd/v2/core/snapshots"
	"github.com/containerd/containerd/v2/core/snapshots/storage"
	"github.com/containerd/nydus-snapshotter/pkg/label"
	"github.com/stretchr/testify/require"
)

// newTestSnapshotter returns a snapshotter on a real metastore whose nydusd
// unmounts are recorded instead of performed.
func newTestSnapshotter(t *testing.T) (*snapshotter, *[]string) {
	root := t.TempDir()
	ms, err := storage.NewMetaStore(filepath.Join(root, "metadata.db"))
	require.NoError(t, err)
	t.Cleanup(func() { ms.Close() })

	var umounted []string
	o := &snapshotter{root: root, ms: ms}
	o.umountIfUnused = func(_ context.Context, metaID string, inUse func() (bool, error)) error {
		used, err := inUse()
		if err == nil && !used {
			umounted = append(umounted, metaID)
		}
		return err
	}
	return o, &umounted
}

// commit creates a committed snapshot name on parent with labels, returning its ID.
func commit(t *testing.T, o *snapshotter, name, parent string, labels map[string]string) string {
	ctx, tx, err := o.ms.TransactionContext(context.Background(), true)
	require.NoError(t, err)
	_, err = storage.CreateSnapshot(ctx, snapshots.KindActive, "extract-"+name, parent)
	require.NoError(t, err)
	id, err := storage.CommitActive(ctx, "extract-"+name, name, snapshots.Usage{}, snapshots.WithLabels(labels))
	require.NoError(t, err)
	require.NoError(t, tx.Commit())
	return id
}

func create(t *testing.T, o *snapshotter, kind snapshots.Kind, key, parent string) {
	ctx, tx, err := o.ms.TransactionContext(context.Background(), true)
	require.NoError(t, err)
	_, err = storage.CreateSnapshot(ctx, kind, key, parent)
	require.NoError(t, err)
	require.NoError(t, tx.Commit())
}

// nydusImage commits a nydus image (one blob layer plus its bootstrap layer) and
// returns the bootstrap snapshot's name and ID: the ID nydusd is mounted under.
func nydusImage(t *testing.T, o *snapshotter, name string) (string, string) {
	commit(t, o, name+"-blob", "", map[string]string{
		label.NydusDataLayer: "true",
		label.CRILayerDigest: "sha256:" + name + "blob",
	})
	return name, commit(t, o, name, name+"-blob", map[string]string{label.NydusMetaLayer: "true"})
}

func TestRemoveReleasesImageOnLastContainer(t *testing.T) {
	o, umounted := newTestSnapshotter(t)
	ctx := context.Background()

	imgA, idA := nydusImage(t, o, "a")
	imgB, idB := nydusImage(t, o, "b")
	oci := "oci"
	commit(t, o, oci, "", nil)

	create(t, o, snapshots.KindActive, "a-c1", imgA)
	create(t, o, snapshots.KindActive, "a-c2", imgA)
	create(t, o, snapshots.KindView, "a-view", imgA)
	create(t, o, snapshots.KindActive, "b-c1", imgB)
	create(t, o, snapshots.KindActive, "oci-c1", oci)

	steps := []struct {
		remove string
		want   []string
	}{
		// Other containers and a view of image a still use its nydusd.
		{"a-c1", nil},
		{"a-c2", nil},
		// Last user of a gone: its nydusd stops; b's is untouched.
		{"a-view", []string{idA}},
		// Containers not on a nydus image never stop anything.
		{"oci-c1", []string{idA}},
		{"b-c1", []string{idA, idB}},
		// Removing the image itself goes through the existing Umount path.
		{imgA, []string{idA, idB}},
	}
	for _, s := range steps {
		require.NoError(t, o.Remove(ctx, s.remove), s.remove)
		require.Equal(t, s.want, *umounted, "after removing %s", s.remove)
	}
}

func TestReleasedImageRemountsOnNextContainer(t *testing.T) {
	o, umounted := newTestSnapshotter(t)
	ctx := context.Background()
	img, id := nydusImage(t, o, "a")

	create(t, o, snapshots.KindActive, "c1", img)
	require.NoError(t, o.Remove(ctx, "c1"))
	require.Equal(t, []string{id}, *umounted)

	// A new container from the same image resolves to the same bootstrap snapshot,
	// which is what Prepare passes to fs.Mount to start a fresh nydusd.
	create(t, o, snapshots.KindActive, "c2", img)
	metaID, _, err := o.findMetaLayer(ctx, "c2")
	require.NoError(t, err)
	require.Equal(t, id, metaID)

	// And while it runs, the image counts as in use.
	used, err := o.imageInUse(ctx, id)
	require.NoError(t, err)
	require.True(t, used)
}

func TestCachedImageBlobIDs(t *testing.T) {
	o, _ := newTestSnapshotter(t)
	nydusImage(t, o, "a")
	nydusImage(t, o, "b")
	commit(t, o, "oci", "", map[string]string{label.CRILayerDigest: "sha256:ocilayer"})

	ctx, tx, err := o.ms.TransactionContext(context.Background(), false)
	require.NoError(t, err)
	defer func() { require.NoError(t, tx.Rollback()) }()

	ids, err := cachedImageBlobIDs(ctx)
	require.NoError(t, err)
	require.Equal(t, map[string]bool{"ablob": true, "bblob": true}, ids)
}
