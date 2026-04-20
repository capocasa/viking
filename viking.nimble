# Package

version       = "0.1.3"
author        = "Carlo"
description   = "CLI tool to submit German VAT advance returns (Umsatzsteuervoranmeldung) via ERiC"
license       = "MIT"
srcDir        = "src"
bin           = @["viking"]

# Dependencies

requires "nim >= 2.0.0"
requires "cligen >= 1.7.0"
requires "zippy >= 0.10.0"

# Tasks

task docs, "Generate HTML docs (API + user guide) into doc/":
  rmDir "doc/api"
  mkDir "doc/api"
  exec "nim doc --project --index:on --outdir:doc/api src/viking.nim"
  exec "nim rst2html --outdir:doc docs.rst"
  echo "Wrote doc/docs.html and doc/api/*.html"
