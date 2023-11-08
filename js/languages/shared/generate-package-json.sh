#!/usr/bin/env bash
set -eu

LANG=$1
VERSION=$2

cat <<EOF
{
  "name": "@semgrep/lang-${LANG}",
  "version": "${VERSION}",
  "description": "Semgrep ${LANG} parser",
  "files": [
    "dist/index.cjs",
    "dist/index.mjs",
    "dist/index.d.ts",
    "dist/semgrep-parser.wasm"
  ],
  "types": "dist/index.d.ts",
  "exports": {
    ".": {
      "require": "./dist/index.cjs",
      "import": "./dist/index.mjs"
    }
  },
  "scripts": {
    "test": "jest"
  },
  "author": "Semgrep, Inc.",
  "license": "LGPL-2.1",
  "devDependencies": {
    "esbuild": "^0.17.17",
    "jest": "^29.5.0"
  },
  "dependencies": {
    "cross-dirname": "^0.1.0"
  }
}
EOF
