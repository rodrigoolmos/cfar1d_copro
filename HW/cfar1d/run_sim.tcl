# Validar si la variable no está vacía
if {$top_simu == ""} {
    error "No se especificó el nombre del módulo top.!!!!!!!!!!!!!!!!"
} else {
    puts "Simulando el módulo top: $top_simu"
}

# Define el directorio de trabajo
cd ./questasim

# Crea una librería de trabajo
vlib work

# Definir la ruta donde están los archivos .sv
set sv_path ../

# Buscar todos los archivos .sv en la ruta especificada
set sv_files [glob -nocomplain -directory $sv_path *.sv]

# Compilar cada archivo encontrado
foreach file $sv_files {
    vlog +sv $file
}

# Carga el testbench o módulo principal en QuestaSim, habilitando el rastreo de aserciones.
vsim -assertdebug -voptargs=+acc work.$top_simu

# Ejecuta la simulación completa hasta que el testbench haga $finish
run -all
