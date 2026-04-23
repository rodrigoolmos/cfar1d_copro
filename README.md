# cfar1d_copro

Coprocesador CFAR 1D para sistemas RISC-V con interfaz CV-X-IF. El repositorio
incluye el hardware SystemVerilog del acelerador, un envoltorio de coprocesador
CV-X-IF, testbenches de simulacion y ejemplos software para bare-metal y Linux.

## Contenido del repositorio

```text
.
|-- HW/
|   `-- cvxif_cfar1d/
|       |-- cvxif_example_coprocessor1.sv   # Top del coprocesador CV-X-IF
|       |-- copro_alu.sv                    # Control de instrucciones CFAR
|       |-- instr_decoder.sv                # Decodificador de instrucciones custom
|       |-- compressed_instr_decoder.sv     # Decodificador de instrucciones comprimidas
|       |-- include/
|       |   `-- cvxif_instr_pkg.sv          # Opcodes y patrones de instruccion
|       `-- cfar1d/
|           |-- cfar_1d.sv                  # Nucleo CFAR 1D
|           |-- tree_adder.sv               # Sumador en arbol parametrizable
|           |-- adder.sv
|           |-- tb_cfar_1d.sv               # Testbench del nucleo CFAR
|           |-- tb_tree_adder.sv            # Testbench del sumador en arbol
|           |-- run.sh                      # Lanzador de simulacion QuestaSim
|           `-- run_sim.tcl                 # Script Tcl de compilacion/simulacion
`-- sw/
    |-- baremetal_example/
    |   `-- systest.c                       # Prueba bare-metal SW vs HW
    `-- linux_example/
        `-- linux.c                         # Prueba Linux user mode SW vs HW
```

## Descripcion funcional

El acelerador implementa un detector CFAR 1D basado en una ventana deslizante.
Para cada muestra de entrada:

1. Inserta la muestra en una ventana de hasta `MAX_WINDOW_CELLS` celdas.
2. Espera a que la ventana tenga suficientes muestras.
3. Suma las celdas de entrenamiento configuradas a ambos lados de la celda bajo
   prueba.
4. Calcula la media de entrenamiento.
5. Multiplica la media por `alpha` para obtener el umbral.
6. Compara la celda bajo prueba con el umbral.
7. Devuelve `detection_map[0] = 1` si hay deteccion, o `0` si no la hay.

La ventana se organiza respecto a la celda bajo prueba con estos parametros:

```text
[training right][guard right][CUT][guard left][training left]
```

La posicion de la celda bajo prueba es:

```text
cut = training_cells_right + guard_cells_right
```

El tamano de ventana usado por una configuracion es:

```text
window_size = training_left + training_right + guard_left + guard_right + 1
```

## Bloques hardware

### `cfar_1d.sv`

Nucleo CFAR 1D parametrizable mediante `MAX_WINDOW_CELLS`.

Entradas principales:

- `alpha`: factor multiplicativo del umbral.
- `training_cells_left`, `training_cells_right`: numero de celdas de
  entrenamiento a la izquierda y derecha.
- `guard_cells_left`, `guard_cells_right`: numero de celdas de guarda.
- `start`: acepta una muestra nueva en `data_in`.
- `reset_window`: limpia el estado de la ventana interna.

Salidas principales:

- `done`: indica que el bloque esta listo o que el resultado ya esta disponible.
- `detection_map`: mapa de deteccion de 8 bits. Actualmente se usa el bit 0.

### `tree_adder.sv`

Sumador en arbol pipelined usado para sumar las celdas de entrenamiento. La
latencia es aproximadamente `$clog2(N)` ciclos para `N > 1`.

### `copro_alu.sv`

Conecta el nucleo CFAR con las instrucciones decodificadas desde CV-X-IF. Mantiene
los registros de configuracion (`alpha`, celdas de entrenamiento y celdas de
guarda), lanza ejecuciones CFAR y genera el resultado para writeback cuando la
instruccion `CFAR_RUN` termina.

### `cvxif_example_coprocessor1.sv`

Top del coprocesador. Integra:

- decodificador de instrucciones comprimidas,
- decodificador de instrucciones custom,
- ALU/control CFAR,
- senales de respuesta CV-X-IF para issue, register y result.

## Instrucciones custom

Las instrucciones usan el opcode RISC-V `custom-3` (`0x7b`). Los ejemplos C las
emiten con `.insn r`.

| Operacion | `.insn` | Registros | Efecto |
| --- | --- | --- | --- |
| Reset de ventana | `.insn r 0x7b, 0, 0, x0, x0, x0` | No lee registros | Limpia la ventana interna del CFAR |
| Set alpha | `.insn r 0x7b, 0, 4, x0, rs1, x0` | `rs1` | Configura `alpha = rs1[31:0]` |
| Set training | `.insn r 0x7b, 0, 8, x0, rs1, rs2` | `rs1`, `rs2` | Configura entrenamiento izquierda/derecha |
| Set guard | `.insn r 0x7b, 0, 12, x0, rs1, rs2` | `rs1`, `rs2` | Configura guarda izquierda/derecha |
| Run | `.insn r 0x7b, 1, 16, rd, rs1, x0` | `rs1`, `rd` | Procesa `data_in = rs1[31:0]` y escribe `rd[7:0] = detection_map` |

Los wrappers usados por los ejemplos software son:

```c
static inline void cfar_hw_reset(void)
{
    __asm__ __volatile__(".insn r 0x7b, 0, 0, x0, x0, x0" ::: "memory");
}

static inline void cfar_hw_set_alpha(uint64_t a)
{
    __asm__ __volatile__(".insn r 0x7b, 0, 4, x0, %0, x0" : : "r"(a) : "memory");
}

static inline void cfar_hw_set_training(uint64_t l, uint64_t r)
{
    __asm__ __volatile__(".insn r 0x7b, 0, 8, x0, %0, %1" : : "r"(l), "r"(r) : "memory");
}

static inline void cfar_hw_set_guard(uint64_t l, uint64_t r)
{
    __asm__ __volatile__(".insn r 0x7b, 0, 12, x0, %0, %1" : : "r"(l), "r"(r) : "memory");
}

static inline uint8_t cfar_hw_run(uint64_t x)
{
    uint64_t rd;
    __asm__ __volatile__(".insn r 0x7b, 1, 16, %0, %1, x0" : "=r"(rd) : "r"(x) : "memory");
    return (uint8_t)(rd & 0xffu);
}
```

## Simulacion

Los testbenches incluidos estan pensados para ejecutarse con QuestaSim/ModelSim.
El script `run.sh` compila todos los `.sv` del directorio `HW/cvxif_cfar1d/cfar1d`
y ejecuta el top indicado.

Desde la carpeta del nucleo CFAR:

```sh
cd HW/cvxif_cfar1d/cfar1d
chmod +x run.sh
./run.sh tb_tree_adder
./run.sh tb_cfar_1d
```

El testbench `tb_tree_adder` comprueba:

- suma correcta para vectores validos,
- propagacion de `valid_out`,
- latencia esperada del arbol.

El testbench `tb_cfar_1d` comprueba:

- reset global y `reset_window`,
- configuraciones simetricas y asimetricas,
- casos con entrenamiento solo a izquierda o solo a derecha,
- ventana maxima del test (`MAX_WINDOW_CELLS = 16`),
- detecciones y no detecciones contra un modelo de referencia dentro del propio
  testbench.

## Ejemplos software

### Bare-metal

`sw/baremetal_example/systest.c` ejecuta una prueba de sign-off comparando una
implementacion software de referencia contra las instrucciones CFAR custom.

La prueba:

- genera patrones de entrada deterministas,
- recorre varias configuraciones de `alpha`, entrenamiento y guarda,
- ejecuta multiples semillas,
- mide ciclos con `rdcycle`,
- compara checksums SW y HW,
- reporta speedup agregado.

Compilacion tipica, ajustando el compilador a tu toolchain RISC-V:

```sh
riscv64-unknown-elf-gcc -O2 -march=rv64gc -mabi=lp64d \
  sw/baremetal_example/systest.c -o systest.elf
```

### Linux user mode

`sw/linux_example/linux.c` contiene la misma prueba adaptada para Linux en modo
usuario.

Diferencias principales respecto a bare-metal:

- detecta con `SIGILL` si las instrucciones CFAR custom estan disponibles,
- detecta si `rdcycle` es accesible en user mode,
- usa `CLOCK_MONOTONIC` como alternativa cuando `rdcycle` no esta disponible.

Compilacion tipica:

```sh
riscv64-linux-gnu-gcc -O2 -march=rv64gc -mabi=lp64d \
  sw/linux_example/linux.c -o cfar_linux
```

Ejecucion en la plataforma RISC-V con el coprocesador integrado:

```sh
./cfar_linux
```

Una ejecucion correcta termina con:

```text
PASS (all 112 tests)
```

## Flujo basico de uso

1. Integra `cvxif_example_coprocessor1.sv` en un core RISC-V con CV-X-IF.
2. Asegura que `cvxif_instr_pkg.sv` esta en el orden correcto de compilacion
   antes de los modulos que importan `cvxif_instr_pkg::*`.
3. Configura el detector:

   ```c
   cfar_hw_set_alpha(alpha);
   cfar_hw_set_training(training_left, training_right);
   cfar_hw_set_guard(guard_left, guard_right);
   cfar_hw_reset();
   ```

4. Alimenta muestras con `cfar_hw_run(sample)`.
5. Interpreta el bit 0 del resultado como deteccion/no deteccion.

Ejemplo minimo:

```c
cfar_hw_set_alpha(3);
cfar_hw_set_training(4, 4);
cfar_hw_set_guard(1, 1);
cfar_hw_reset();

for (unsigned i = 0; i < n; ++i) {
    uint8_t detected = cfar_hw_run(samples[i]) & 1u;
    if (detected) {
        /* Procesar deteccion */
    }
}
```

## Requisitos y notas de integracion

- El hardware esta escrito en SystemVerilog.
- Los scripts de simulacion incluidos usan QuestaSim/ModelSim (`vsim`, `vlog`,
  `vlib`).
- El software requiere una toolchain RISC-V que soporte la directiva ensamblador
  `.insn`.
- La plataforma de ejecucion debe implementar el coprocesador CFAR en el opcode
  `custom-3` (`0x7b`); si no, las instrucciones produciran illegal instruction.
- `CFAR_RUN` produce writeback; las instrucciones de configuracion no escriben en
  registro destino.
- `copro_alu.sv` bloquea nuevas instrucciones mientras el nucleo CFAR esta
  ocupado con una ejecucion pendiente.
- `MAX_WINDOW_CELLS` debe ser suficiente para la mayor configuracion usada:

  ```text
  training_left + training_right + guard_left + guard_right + 1 <= MAX_WINDOW_CELLS
  ```

## Licencia

Los archivos fuente conservan las cabeceras de licencia de sus autores. Los
modulos CV-X-IF derivados de Thales indican licencia `Apache-2.0 WITH SHL-2.0`.
Los ejemplos software indican licencia `Apache-2.0`.
