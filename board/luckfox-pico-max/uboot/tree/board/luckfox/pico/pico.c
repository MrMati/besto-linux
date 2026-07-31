// SPDX-License-Identifier: GPL-2.0+
//
// Copyright 2026 Simon Glass <sjg@chromium.org>

#include <asm/global_data.h>

DECLARE_GLOBAL_DATA_PTR;

int dram_init(void)
{
	gd->ram_size = (phys_size_t)CONFIG_LUCKFOX_PICO_DRAM_SIZE_MB << 20;

	return 0;
}

phys_addr_t board_get_usable_ram_top(phys_size_t total_size)
{
	return gd->ram_top;
}
