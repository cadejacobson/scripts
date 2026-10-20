#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

depends() {
    echo systemd systemd-networkd ignition
}

install() {
    inst_multiple /usr/bin/coreos-metadata /usr/bin/mkdir
    inst_simple "${moddir}/afterburn-ignition-fragment.service" \
        "${systemdsystemunitdir}/afterburn-ignition-fragment.service"

    # Only enable fragment generation, not Afterburn's hostname/network services.
    mkdir -p "${initdir}${systemdsystemunitdir}/ignition-complete.target.requires"
    ln -sf "../afterburn-ignition-fragment.service" \
        "${initdir}${systemdsystemunitdir}/ignition-complete.target.requires/afterburn-ignition-fragment.service"
}
