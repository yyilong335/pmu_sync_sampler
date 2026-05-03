| Name                    | Event                          | EventSel | UMask | Fixed/GP        | Notes                 |
| ----------------------- | ------------------------------ | -------: | ----: | --------------- | --------------------- |
| instruction             | Instructions Retired           |     `c0` |  `00` | Fixed Counter 0 |                       |
| ref-cycle               | Reference Cycles               |          |       | Fixed Counter 2 |                       |
| Stall during issue      | `UOPS_ISSUED.STALL_CYCLES`     |     `0e` |  `01` | GP              | `Invert=1`, `CMask=1` |
| Stall during retirement | `UOPS_RETIRED.STALL_CYCLES`    |     `c2` |  `02` | GP              | `Invert=1`, `CMask=1` |
| Load                    | `MEM_INST_RETIRED.ALL_LOADS`   |     `d0` |  `81` | GP              |                       |
| Store                   | `MEM_INST_RETIRED.ALL_STORES`  |     `d0` |  `82` | GP              |                       |
| Branch                  | `BR_INST_RETIRED.ALL_BRANCHES` |     `c4` |  `00` | GP              |                       |
| L1D Read Miss           | `L1D.REPLACEMENT`              |     `51` |  `01` | GP              |                       |
| L1I Read Miss           | `ICACHE_64B.IFLAG_MISS`        |     `83` |  `02` | GP              |                       |
| LLC Miss                | LLC Misses                     |     `2e` |  `41` | GP              |                       |
| LLC Access              | LLC Reference                  |     `2e` |  `4f` | GP              |                       |
