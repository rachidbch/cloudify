#!/usr/bin/env bash
# yazi — blazing fast terminal file manager
# doc: https://yazi-rs.github.io/docs/installation/
# deps: file (prerequisite)

pkg_depends file
pkg_install_release yazi "sxyazi/yazi"
pkg_in_startuprc "alias y=yazi"
