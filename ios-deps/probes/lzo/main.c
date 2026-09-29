#include <lzo/lzo1x.h>

#include <string.h>

int main(void)
{
	static const unsigned char input[] = "OpenTTD";
	unsigned char compressed[64];
	unsigned char restored[sizeof(input)];
	unsigned char work[LZO1X_1_MEM_COMPRESS];
	lzo_uint compressed_size = sizeof(compressed);
	lzo_uint restored_size = sizeof(restored);

	if (lzo_init() != LZO_E_OK) return 1;
	if (lzo1x_1_compress(input, sizeof(input), compressed, &compressed_size, work) != LZO_E_OK) return 2;
	if (lzo1x_decompress_safe(compressed, compressed_size, restored, &restored_size, 0) != LZO_E_OK) return 3;
	return restored_size != sizeof(input) || memcmp(input, restored, sizeof(input)) != 0;
}
