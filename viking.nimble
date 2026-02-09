# Package

version       = "0.1.0"
author        = "Carlo"
description   = "CLI tool to submit German VAT advance returns (Umsatzsteuervoranmeldung) via ERiC"
license       = "MIT"
srcDir        = "src"
bin           = @["viking"]

# Dependencies

requires "nim >= 2.0.0"
requires "dotenv >= 2.0.0"
requires "cligen >= 1.7.0"
