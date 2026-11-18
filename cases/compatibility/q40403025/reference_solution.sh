#!/bin/bash
# `runc start` wants the id of a container that was already created: the container is bench40403025 (`sudo runc list` shows it as "created")
set -e
sudo runc start bench40403025
sudo runc state bench40403025
