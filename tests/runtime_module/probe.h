/* Prototypes for the extern fns of main.orb: the C backend declares none. */
const char* rtmod_probe_upper(const char* s);
const char* rtmod_probe_twice(const char* s);
const char* rtmod_probe_tail(const char* s, long long from);
const char* rtmod_probe_copy_nothing(const char* s);
long long rtmod_mem_sum(long long a, long long b);
const char* rtmod_mem_tail(const char* s, long long from);
const char* rtmod_mem_slot(const char* s);
long long rtmod_mem_bits(double x);
double rtmod_mem_float(long long b);
long long rtmod_res_word_value(long long x);
const char* rtmod_res_word_error(long long x);
const char* rtmod_res_text_value(const char* s);
_Bool rtmod_ptr_is_null(const char* s);
