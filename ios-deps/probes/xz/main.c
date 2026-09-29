#include <lzma.h>

int main(void)
{
	return lzma_version_number() == 0;
}
