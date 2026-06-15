#!/bin/bash

TOP_MODULE="$1"

# Comprobar si se pasó el nombre del módulo top
if [ -z "$TOP_MODULE" ]; then
    echo "Error: Debes especificar el nombre del módulo top como argumento."
    exit 1
fi

echo "Simulando módulo top: $TOP_MODULE"

rm -rf ./questasim
mkdir -p ./questasim
vsim -do "set top_simu $TOP_MODULE; source run_sim.tcl"