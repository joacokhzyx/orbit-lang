/* Interface of runtime/energy.c (generated split; edit by hand from here). */
#ifndef ORBIT_RT_ENERGY_H
#define ORBIT_RT_ENERGY_H

#include "module_prelude.h"


#include "performance.h"
#include "crt_compat.h"
#include <stdio.h>
#include <string.h>

#if defined(__linux__) && !defined(_WIN32)
#include <pthread.h>
#include <time.h>
#include <unistd.h>
#endif

/* Sensor candidates, most common layout first. */
#define ORBIT_ENERGY_CANDIDATE_0 "/sys/class/powercap/intel-rapl:0/energy_uj"
#define ORBIT_ENERGY_CANDIDATE_1 "/sys/class/powercap/intel-rapl:0:0/energy_uj"
#define ORBIT_ENERGY_CANDIDATE_2 "/sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj"
#define ORBIT_ENERGY_IDLE_SAMPLES 5

#if defined(__linux__) && !defined(_WIN32)
#endif

#if defined(__linux__) && !defined(_WIN32)
#endif
void orbit_energy_start(void);
void orbit_energy_stop(void);
int orbit_energy_has_sensor(void);
const char* orbit_energy_source(void);
double orbit_energy_total_joules(void);
double orbit_energy_uptime_s(void);
double orbit_energy_attributable_joules(void);
double orbit_energy_route_joules(uint64_t route_cycles, uint64_t total_cycles);

#endif
