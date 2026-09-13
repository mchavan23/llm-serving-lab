#!/usr/bin/env python3
"""Upload a local model folder to MinIO.

Usage:
    uv run python scripts/upload_model.py <local_dir> <s3_prefix>

Example:
    uv run python scripts/upload_model.py models/qwen-0.5b qwen-0.5b
    -> s3://models/qwen-0.5b/config.json, .../model.safetensors, ...
"""

import argparse
import sys
from pathlib import Path

import boto3
from botocore.client import Config
from botocore.exceptions import ClientError

# __file__ is this file's path. .resolve() makes it absolute and follows any
# symlinks; .parent.parent walks up from scripts/ to the repo root. Doing it
# this way means the script works regardless of the directory it is run from.
REPO_ROOT = Path(__file__).resolve().parent.parent
ENV_FILE = REPO_ROOT / ".env"


def read_env(path: Path) -> dict[str, str]:
    """Parse KEY=VALUE lines from .env without executing the file.

    A shell `source .env` runs the file, so a malformed line becomes a
    command. This only ever splits strings.
    """
    values: dict[str, str] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        # Skip blanks, comments, and anything that is not KEY=VALUE.
        if not line or line.startswith("#") or "=" not in line:
            continue
        # partition splits on the FIRST '=' only, so values containing '='
        # (URLs with query strings, base64 padding) survive intact.
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip()
    return values


def make_client(env: dict[str, str]):
    """Build an S3 client pointed at MinIO instead of AWS."""
    return boto3.client(
        "s3",
        # Without endpoint_url, boto3 talks to real AWS S3.
        endpoint_url=env["MINIO_ENDPOINT"],
        aws_access_key_id=env["MINIO_ROOT_USER"],
        aws_secret_access_key=env["MINIO_ROOT_PASSWORD"],
        # MinIO ignores the region, but the AWS signature algorithm includes
        # it, so botocore refuses to sign without one. Any value works as
        # long as it is consistent; us-east-1 is the conventional default.
        region_name="us-east-1",
        # THE IMPORTANT ONE. AWS defaults to virtual-host addressing:
        #   https://<bucket>.s3.amazonaws.com/<key>
        # Against MinIO that becomes http://models.localhost:9000/... which
        # does not resolve. Path style keeps the bucket in the path:
        #   http://localhost:9000/<bucket>/<key>
        # KServe's storage-initializer needs the same setting in week 2.
        config=Config(s3={"addressing_style": "path"}),
    )


def ensure_bucket(s3, bucket: str) -> None:
    """Create the bucket if it does not already exist (idempotent)."""
    try:
        # head_bucket asks "does this exist and can I see it?" without
        # transferring any data. Succeeds silently if so.
        s3.head_bucket(Bucket=bucket)
        print(f"bucket '{bucket}' already exists")
    except ClientError as err:
        # boto3 signals "missing" by raising, not by returning None, so the
        # absence has to be caught and inspected. Anything other than a
        # not-found is a real problem (bad credentials, server down) and
        # must propagate rather than be swallowed.
        code = err.response["Error"]["Code"]
        if code not in ("404", "NoSuchBucket"):
            raise
        s3.create_bucket(Bucket=bucket)
        print(f"created bucket '{bucket}'")


def upload_folder(s3, bucket: str, local_dir: Path, prefix: str) -> int:
    """Upload every file under local_dir, preserving relative structure."""
    # rglob("*") walks recursively. Filtering on is_file() drops directories,
    # which S3 has no concept of - the illusion of folders comes purely from
    # '/' characters in key names.
    files = sorted(p for p in local_dir.rglob("*") if p.is_file())
    if not files:
        sys.exit(f"error: no files found under {local_dir}")

    for path in files:
        # relative_to strips the local prefix so an absolute path like
        # /root/models/qwen-0.5b/config.json becomes config.json.
        # as_posix() forces forward slashes - S3 keys are not filesystem
        # paths, and a backslash would become part of the name.
        key = f"{prefix}/{path.relative_to(local_dir).as_posix()}"
        # upload_file handles multipart upload automatically for large files,
        # which matters for multi-GB safetensors shards later.
        s3.upload_file(str(path), bucket, key)
        print(f"  {key}  ({path.stat().st_size:,} bytes)")

    return len(files)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("local_dir", type=Path, help="folder to upload")
    parser.add_argument("prefix", help="key prefix in the bucket, e.g. qwen-0.5b")
    args = parser.parse_args()

    if not args.local_dir.is_dir():
        sys.exit(f"error: {args.local_dir} is not a directory")

    env = read_env(ENV_FILE)
    bucket = env["MINIO_BUCKET"]

    s3 = make_client(env)
    ensure_bucket(s3, bucket)

    print(f"uploading {args.local_dir} -> s3://{bucket}/{args.prefix}/")
    count = upload_folder(s3, bucket, args.local_dir, args.prefix)
    print(f"done: {count} files")


# Only run main() when this file is executed directly, not when it is
# imported by another module. Standard Python guard.
if __name__ == "__main__":
    main()
