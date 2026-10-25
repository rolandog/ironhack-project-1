# Building, publishing and pinning images

Images are multi-arch (linux/amd64 and linux/arm64) manifest lists on Docker Hub.
Everything that deploys them pins `tag@sha256:<index digest>`.

## Release an image set

```sh
export DOCKERHUB_USER=<hub-user>
scripts/rg-build-images.sh --tag=X.Y.Z --push      # builds, pushes, verifies
scripts/rg-build-images.sh --tag=X.Y.Z --verify    # re-check what the registry holds
```

- A tag is never reused: `--push` refuses a tag that already exists.
- `--only=NAME` limits the run to vote, result or worker. Each image has its own version.
- `latest` moves only with `--latest`. Nothing in this repository consumes it.
- The script prints `NAME_IMAGE_TAG=tag@sha256:...` lines. Paste them into
  `.env.example` and `.env`, and the matching `rg_*_tag` values in `ansible/site.yml`.

## Which digest is the right one

Only the digest the registry reports for the tag counts:

```sh
skopeo inspect --format '{{.Digest}}' docker://docker.io/$DOCKERHUB_USER/vote:0.2.0
```

These are not registry digests: the image ID printed at the end of `podman build`, and
the `DIGEST` column of `podman images --digests` for a local manifest list.

## Pitfalls seen in this project

- `podman build --manifest NAME` appends to an existing list of that name. Remove it
  first (`podman manifest rm NAME`); the script does. A list with duplicate entries
  was pushed once as `result:1.2.0`; use 1.2.1.
- `skopeo` rejects `name:tag@digest`; strip the tag (`name@digest`).
- Podman ignores the tag in `name:tag@digest` and does not check it against the digest.
- Check the architecture from the ELF header: `od -An -tx1 -j18 -N2 /bin/sh`
  prints `3e 00` on amd64 and `b7 00` on arm64.

## Check the pins end to end

```sh
scripts/rg-smoke.sh --pinned --user=$DOCKERHUB_USER
```
