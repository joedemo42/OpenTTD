#include <zlib.h>

int main(void)
{
	return zlibVersion() == Z_NULL;
}
