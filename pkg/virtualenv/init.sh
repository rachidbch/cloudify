#!/usr/bin/env bash
# if error 'requirement already satisfied', try '$ sudo pip uninstall virtualenv' first.
[ -z "$(which virtualenv)" ] || python3 -m pip install --user virtualenv
