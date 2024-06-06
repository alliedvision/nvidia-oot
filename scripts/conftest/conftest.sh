#!/bin/sh
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Copyright (c) 2023-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.

PATH="${PATH}:/bin:/sbin:/usr/bin"

# make sure we are in the directory containing this script
SCRIPTDIR=`dirname $0`
cd $SCRIPTDIR

CC="$1"
ARCH=$2
SOURCES=$3
HEADERS=$SOURCES/include
OUTPUT=$4
XEN_PRESENT=1
PREEMPT_RT_PRESENT=0

# VGX_BUILD parameter defined only for VGX builds (vGPU Host driver)
# VGX_KVM_BUILD parameter defined only vGPU builds on KVM hypervisor
# GRID_BUILD parameter defined only for GRID builds (GRID Guest driver)
# GRID_BUILD_CSP parameter defined only for GRID CSP builds (GRID Guest driver for CSPs)

test_xen() {
    #
    # Determine if the target kernel is a Xen kernel. It used to be
    # sufficient to check for CONFIG_XEN, but the introduction of
    # modular para-virtualization (CONFIG_PARAVIRT, etc.) and
    # Xen guest support, it is no longer possible to determine the
    # target environment at build time. Therefore, if both
    # CONFIG_XEN and CONFIG_PARAVIRT are present, text_xen() treats
    # the kernel as a stand-alone kernel.
    #
    if ! test_configuration_option CONFIG_XEN ||
         test_configuration_option CONFIG_PARAVIRT; then
        XEN_PRESENT=0
    fi
}

append_conftest() {
    #
    # Echo data from stdin: this is a transitional function to make it easier
    # to port conftests from drivers with parallel conftest generation to
    # older driver versions
    #

    while read LINE; do
        echo ${LINE}
    done
}

test_header_presence() {
    #
    # Determine if the given header file (which may or may not be
    # present) is provided by the target kernel.
    #
    # Input:
    #   $1: relative file path
    #
    # This routine creates an upper case, underscore version of each of the
    # relative file paths, and uses that as the token to either define or
    # undefine in a C header file. For example, linux/fence.h becomes
    # NV_LINUX_FENCE_H_PRESENT, and that is either defined or undefined, in the
    # output (which goes to stdout, just like the rest of this file).

    TEST_CFLAGS="-E -M $CFLAGS"

    file="$1"
    file_define=NV_`echo $file | tr '/.\-a-z' '___A-Z'`_PRESENT

    CODE="#include <$file>"

    if echo "$CODE" | $CC $TEST_CFLAGS - > /dev/null 2>&1; then
        echo "#define $file_define"
    else
        # If preprocessing failed, it could have been because the header
        # file under test is not present, or because it is present but
        # depends upon the inclusion of other header files. Attempting
        # preprocessing again with -MG will ignore a missing header file
        # but will still fail if the header file is present.
        if echo "$CODE" | $CC $TEST_CFLAGS -MG - > /dev/null 2>&1; then
            echo "#undef $file_define"
        else
            echo "#define $file_define"
        fi
    fi
}

build_cflags() {
    ISYSTEM=`$CC -print-file-name=include 2> /dev/null`
    BASE_CFLAGS="-O2 -D__KERNEL__ \
-DKBUILD_BASENAME=\"#conftest$$\" -DKBUILD_MODNAME=\"#conftest$$\" \
-nostdinc -isystem $ISYSTEM \
-Wno-implicit-function-declaration -Wno-strict-prototypes"

    if [ "$OUTPUT" != "$SOURCES" ]; then
        OUTPUT_CFLAGS="-I$OUTPUT/include2 -I$OUTPUT/include"
        if [ -f "$OUTPUT/include/generated/autoconf.h" ]; then
            AUTOCONF_FILE="$OUTPUT/include/generated/autoconf.h"
        else
            AUTOCONF_FILE="$OUTPUT/include/linux/autoconf.h"
        fi
    else
        if [ -f "$HEADERS/generated/autoconf.h" ]; then
            AUTOCONF_FILE="$HEADERS/generated/autoconf.h"
        else
            AUTOCONF_FILE="$HEADERS/linux/autoconf.h"
        fi
    fi

    test_xen

    if [ "$XEN_PRESENT" != "0" ]; then
        MACH_CFLAGS="-I$HEADERS/asm/mach-xen"
    fi

    KERNEL_ARCH="$ARCH"

    if [ "$ARCH" = "i386" -o "$ARCH" = "x86_64" ]; then
        if [ -d "$SOURCES/arch/x86" ]; then
            KERNEL_ARCH="x86"
        fi
    fi

    SOURCE_HEADERS="$HEADERS"
    SOURCE_ARCH_HEADERS="$SOURCES/arch/$KERNEL_ARCH/include"
    OUTPUT_HEADERS="$OUTPUT/include"
    OUTPUT_ARCH_HEADERS="$OUTPUT/arch/$KERNEL_ARCH/include"

    # Look for mach- directories on this arch, and add it to the list of
    # includes if that platform is enabled in the configuration file, which
    # may have a definition like this:
    #   #define CONFIG_ARCH_<MACHUPPERCASE> 1
    for _mach_dir in `ls -1d $SOURCES/arch/$KERNEL_ARCH/mach-* 2>/dev/null`; do
        _mach=`echo $_mach_dir | \
            sed -e "s,$SOURCES/arch/$KERNEL_ARCH/mach-,," | \
            tr 'a-z' 'A-Z'`
        grep "CONFIG_ARCH_$_mach \+1" $AUTOCONF_FILE > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            MACH_CFLAGS="$MACH_CFLAGS -I$_mach_dir/include"
        fi
    done

    if [ "$ARCH" = "arm" ]; then
        MACH_CFLAGS="$MACH_CFLAGS -D__LINUX_ARM_ARCH__=7"
    fi

    # Add the mach-default includes (only found on x86/older kernels)
    MACH_CFLAGS="$MACH_CFLAGS -I$SOURCE_HEADERS/asm-$KERNEL_ARCH/mach-default"
    MACH_CFLAGS="$MACH_CFLAGS -I$SOURCE_ARCH_HEADERS/asm/mach-default"

    CFLAGS="$BASE_CFLAGS $MACH_CFLAGS $OUTPUT_CFLAGS -include $AUTOCONF_FILE"
    CFLAGS="$CFLAGS -I$SOURCE_HEADERS"
    CFLAGS="$CFLAGS -I$SOURCE_HEADERS/uapi"
    CFLAGS="$CFLAGS -I$SOURCE_HEADERS/xen"
    CFLAGS="$CFLAGS -I$OUTPUT_HEADERS/generated/uapi"
    CFLAGS="$CFLAGS -I$SOURCE_ARCH_HEADERS"
    CFLAGS="$CFLAGS -I$SOURCE_ARCH_HEADERS/uapi"
    CFLAGS="$CFLAGS -I$OUTPUT_ARCH_HEADERS/generated"
    CFLAGS="$CFLAGS -I$OUTPUT_ARCH_HEADERS/generated/uapi"

    if [ -n "$BUILD_PARAMS" ]; then
        CFLAGS="$CFLAGS -D$BUILD_PARAMS"
    fi

    # Check if gcc supports asm goto and set CC_HAVE_ASM_GOTO if it does.
    # Older kernels perform this check and set this flag in Kbuild, and since
    # conftest.sh runs outside of Kbuild it ends up building without this flag.
    # Starting with commit e9666d10a5677a494260d60d1fa0b73cc7646eb3 this test
    # is done within Kconfig, and the preprocessor flag is no longer needed.

    GCC_GOTO_SH="$SOURCES/build/gcc-goto.sh"

    if [ -f "$GCC_GOTO_SH" ]; then
        # Newer versions of gcc-goto.sh don't print anything on success, but
        # this is okay, since it's no longer necessary to set CC_HAVE_ASM_GOTO
        # based on the output of those versions of gcc-goto.sh.
        if [ `/bin/sh "$GCC_GOTO_SH" "$CC"` = "y" ]; then
            CFLAGS="$CFLAGS -DCC_HAVE_ASM_GOTO"
        fi
    fi

    #
    # If CONFIG_HAVE_FENTRY is enabled and gcc supports -mfentry flags then set
    # CC_USING_FENTRY and add -mfentry into cflags.
    #
    # linux/ftrace.h file indirectly gets included into the conftest source and
    # fails to get compiled, because conftest.sh runs outside of Kbuild it ends
    # up building without -mfentry and CC_USING_FENTRY flags.
    #
    grep "CONFIG_HAVE_FENTRY \+1" $AUTOCONF_FILE > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "" > conftest$$.c

        $CC -mfentry -c -x c conftest$$.c > /dev/null 2>&1
        rm -f conftest$$.c

        if [ -f conftest$$.o ]; then
            rm -f conftest$$.o

            CFLAGS="$CFLAGS -mfentry -DCC_USING_FENTRY"
        fi
    fi
}

CONFTEST_PREAMBLE="#include \"conftest/headers.h\"
    #if defined(NV_LINUX_KCONFIG_H_PRESENT)
    #include <linux/kconfig.h>
    #endif
    #if defined(NV_GENERATED_AUTOCONF_H_PRESENT)
    #include <generated/autoconf.h>
    #else
    #include <linux/autoconf.h>
    #endif
    #if defined(CONFIG_XEN) && \
        defined(CONFIG_XEN_INTERFACE_VERSION) &&  !defined(__XEN_INTERFACE_VERSION__)
    #define __XEN_INTERFACE_VERSION__ CONFIG_XEN_INTERFACE_VERSION
    #endif
    #if defined(CONFIG_KASAN) && defined(CONFIG_ARM64)
    #if defined(CONFIG_KASAN_SW_TAGS)
    #define KASAN_SHADOW_SCALE_SHIFT 4
    #else
    #define KASAN_SHADOW_SCALE_SHIFT 3
    #endif
    #endif"

test_configuration_option() {
    #
    # Check to see if the given configuration option is defined
    #

    get_configuration_option $1 >/dev/null 2>&1

    return $?

}

set_configuration() {
    #
    # Set a specific configuration option.  This function is called to always
    # enable a configuration, in order to verify whether the test code for that
    # configuration is no longer required and the corresponding
    # conditionally-compiled code in the driver can be removed.
    #
    DEF="$1"

    if [ "$3" = "" ]
    then
        VAL=""
        CAT="$2"
    else
        VAL="$2"
        CAT="$3"
    fi

    echo "#define ${DEF} ${VAL}" | append_conftest "${CAT}"
}

unset_configuration() {
    #
    # Un-set a specific configuration option.  This function is called to
    # always disable a configuration, in order to verify whether the test
    # code for that configuration is no longer required and the corresponding
    # conditionally-compiled code in the driver can be removed.
    #
    DEF="$1"
    CAT="$2"

    echo "#undef ${DEF}" | append_conftest "${CAT}"
}

compile_check_conftest() {
    #
    # Compile the current conftest C file and check+output the result
    #
    CODE="$1"
    DEF="$2"
    VAL="$3"
    CAT="$4"

    echo "$CONFTEST_PREAMBLE
    $CODE" > conftest$$.c

    $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
    rm -f conftest$$.c

    if [ -f conftest$$.o ]; then
        rm -f conftest$$.o
        if [ "${CAT}" = "functions" ]; then
            #
            # The logic for "functions" compilation tests is inverted compared to
            # other compilation steps: if the function is present, the code
            # snippet will fail to compile because the function call won't match
            # the prototype. If the function is not present, the code snippet
            # will produce an object file with the function as an unresolved
            # symbol.
            #
            echo "#undef ${DEF}" | append_conftest "${CAT}"
        else
            echo "#define ${DEF} ${VAL}" | append_conftest "${CAT}"
        fi
        return
    else
        if [ "${CAT}" = "functions" ]; then
            echo "#define ${DEF} ${VAL}" | append_conftest "${CAT}"
        else
            echo "#undef ${DEF}" | append_conftest "${CAT}"
        fi
        return
    fi
}

export_symbol_present_conftest() {
    #
    # Check Module.symvers to see whether the given symbol is present.
    #

    SYMBOL="$1"
    TAB='	'

    if grep -e "${TAB}${SYMBOL}${TAB}.*${TAB}EXPORT_SYMBOL.*\$" \
               "$OUTPUT/Module.symvers" >/dev/null 2>&1; then
        echo "#define NV_IS_EXPORT_SYMBOL_PRESENT_$SYMBOL 1" |
            append_conftest "symbols"
    else
        # May be a false negative if Module.symvers is absent or incomplete,
        # or if the Module.symvers format changes.
        echo "#define NV_IS_EXPORT_SYMBOL_PRESENT_$SYMBOL 0" |
            append_conftest "symbols"
    fi
}

export_symbol_gpl_conftest() {
    #
    # Check Module.symvers to see whether the given symbol is present and its
    # export type is GPL-only (including deprecated GPL-only symbols).
    #

    SYMBOL="$1"
    TAB='	'

    if grep -e "${TAB}${SYMBOL}${TAB}.*${TAB}EXPORT_\(UNUSED_\)*SYMBOL_GPL\$" \
               "$OUTPUT/Module.symvers" >/dev/null 2>&1; then
        echo "#define NV_IS_EXPORT_SYMBOL_GPL_$SYMBOL 1" |
            append_conftest "symbols"
    else
        # May be a false negative if Module.symvers is absent or incomplete,
        # or if the Module.symvers format changes.
        echo "#define NV_IS_EXPORT_SYMBOL_GPL_$SYMBOL 0" |
            append_conftest "symbols"
    fi
}

get_configuration_option() {
    #
    # Print the value of given configuration option, if defined
    #
    RET=1
    OPTION=$1

    OLD_FILE="linux/autoconf.h"
    NEW_FILE="generated/autoconf.h"
    FILE=""

    if [ -f $HEADERS/$NEW_FILE -o -f $OUTPUT/include/$NEW_FILE ]; then
        FILE=$NEW_FILE
    elif [ -f $HEADERS/$OLD_FILE -o -f $OUTPUT/include/$OLD_FILE ]; then
        FILE=$OLD_FILE
    fi

    if [ -n "$FILE" ]; then
        #
        # We are looking at a configured source tree; verify
        # that its configuration includes the given option
        # via a compile check, and print the option's value.
        #

        if [ -f $HEADERS/$FILE ]; then
            INCLUDE_DIRECTORY=$HEADERS
        elif [ -f $OUTPUT/include/$FILE ]; then
            INCLUDE_DIRECTORY=$OUTPUT/include
        else
            return 1
        fi

        echo "#include <$FILE>
        #ifndef $OPTION
        #error $OPTION not defined!
        #endif

        $OPTION
        " > conftest$$.c

        $CC -E -P -I$INCLUDE_DIRECTORY -o conftest$$ conftest$$.c > /dev/null 2>&1

        if [ -e conftest$$ ]; then
            tr -d '\r\n\t ' < conftest$$
            RET=$?
        fi

        rm -f conftest$$.c conftest$$
    else
        CONFIG=$OUTPUT/.config
        if [ -f $CONFIG ] && grep "^$OPTION=" $CONFIG; then
            grep "^$OPTION=" $CONFIG | cut -f 2- -d "="
            RET=$?
        fi
    fi

    return $RET

}

check_for_ib_peer_memory_symbols() {
    kernel_dir="$1"
    module_symvers="${kernel_dir}/Module.symvers"

    sym_ib_register="ib_register_peer_memory_client"
    sym_ib_unregister="ib_unregister_peer_memory_client"
    tab='	'

    # Return 0 for true(no errors), 1 for false
    if [ ! -f "${module_symvers}" ]; then
        return 1
    fi

    if grep -e "${tab}${sym_ib_register}${tab}.*${tab}EXPORT_SYMBOL.*\$"    \
               "${module_symvers}" > /dev/null 2>&1 &&
       grep -e "${tab}${sym_ib_unregister}${tab}.*${tab}EXPORT_SYMBOL.*\$"  \
               "${module_symvers}" > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

compile_test() {
    case "$1" in
        set_memory_uc)
            #
            # Determine if the set_memory_uc() function is present.
            # It does not exist on all architectures.
            #
            CODE="
            #include <linux/types.h>
            #if defined(NV_ASM_SET_MEMORY_H_PRESENT)
            #if defined(NV_ASM_PGTABLE_TYPES_H_PRESENT)
            #include <asm/pgtable_types.h>
            #endif
            #if defined(NV_ASM_PAGE_H_PRESENT)
            #include <asm/page.h>
            #endif
            #include <asm/set_memory.h>
            #else
            #include <asm/cacheflush.h>
            #endif
            void conftest_set_memory_uc(void) {
                set_memory_uc();
            }"

            compile_check_conftest "$CODE" "NV_SET_MEMORY_UC_PRESENT" "" "functions"
        ;;

        set_memory_array_uc)
            #
            # Determine if the set_memory_array_uc() function is present.
            # It does not exist on all architectures.
            #
            CODE="
            #include <linux/types.h>
            #if defined(NV_ASM_SET_MEMORY_H_PRESENT)
            #if defined(NV_ASM_PGTABLE_TYPES_H_PRESENT)
            #include <asm/pgtable_types.h>
            #endif
            #if defined(NV_ASM_PAGE_H_PRESENT)
            #include <asm/page.h>
            #endif
            #include <asm/set_memory.h>
            #else
            #include <asm/cacheflush.h>
            #endif
            void conftest_set_memory_array_uc(void) {
                set_memory_array_uc();
            }"

            compile_check_conftest "$CODE" "NV_SET_MEMORY_ARRAY_UC_PRESENT" "" "functions"
        ;;

        sysfs_slab_unlink)
            #
            # Determine if the sysfs_slab_unlink() function is present.
            #
            # This test is useful to check for the presence a fix for the deferred
            # kmem_cache destroy feature (see nvbug: 2543505).
            #
            # Added by commit d50d82faa0c9 ("slub: fix failure when we delete and
            # create a slab cache") in 4.18 (2018-06-27).
            #
            CODE="
            #include <linux/slab.h>
            void conftest_sysfs_slab_unlink(void) {
                sysfs_slab_unlink();
            }"

            compile_check_conftest "$CODE" "NV_SYSFS_SLAB_UNLINK_PRESENT" "" "functions"
        ;;

        list_is_first)
            #
            # Determine if the list_is_first() function is present.
            #
            # Added by commit 70b44595eafe ("mm, compaction: use free lists
            # to quickly locate a migration source") in 5.1 (2019-03-05)
            #
            CODE="
            #include <linux/list.h>
            void conftest_list_is_first(void) {
                list_is_first();
            }"

            compile_check_conftest "$CODE" "NV_LIST_IS_FIRST_PRESENT" "" "functions"
        ;;

        set_pages_uc)
            #
            # Determine if the set_pages_uc() function is present.
            # It does not exist on all architectures.
            #
            CODE="
            #include <linux/types.h>
            #if defined(NV_ASM_SET_MEMORY_H_PRESENT)
            #if defined(NV_ASM_PGTABLE_TYPES_H_PRESENT)
            #include <asm/pgtable_types.h>
            #endif
            #if defined(NV_ASM_PAGE_H_PRESENT)
            #include <asm/page.h>
            #endif
            #include <asm/set_memory.h>
            #else
            #include <asm/cacheflush.h>
            #endif
            void conftest_set_pages_uc(void) {
                set_pages_uc();
            }"

            compile_check_conftest "$CODE" "NV_SET_PAGES_UC_PRESENT" "" "functions"
        ;;

        set_pages_array_uc)
            #
            # Determine if the set_pages_array_uc() function is present.
            # It does not exist on all architectures.
            #
            # set_pages_array_uc() was added by commit
            # 0f3507555f6fa4acbc85a646d6e8766230db38fc ("x86, CPA: Add
            # set_pages_arrayuc and set_pages_array_wb") in v2.6.30-rc1 (Thu Mar
            # 19 14:51:15 2009)
            #
            CODE="
            #include <linux/types.h>
            #if defined(NV_ASM_SET_MEMORY_H_PRESENT)
            #if defined(NV_ASM_PGTABLE_TYPES_H_PRESENT)
            #include <asm/pgtable_types.h>
            #endif
            #if defined(NV_ASM_PAGE_H_PRESENT)
            #include <asm/page.h>
            #endif
            #include <asm/set_memory.h>
            #else
            #include <asm/cacheflush.h>
            #endif
            void conftest_set_pages_array_uc(void) {
                set_pages_array_uc();
            }"

            compile_check_conftest "$CODE" "NV_SET_PAGES_ARRAY_UC_PRESENT" "" "functions"
        ;;

        flush_cache_all)
            #
            # Determine if flush_cache_all() function is present
            #
            # flush_cache_all() was removed by commit id
            # 68234df4ea79 ("arm64: kill flush_cache_all()") in 4.2 (2015-04-20)
            # for aarch64
            #
            CODE="
            #include <asm/cacheflush.h>
            int conftest_flush_cache_all(void) {
                return flush_cache_all();
            }"
            compile_check_conftest "$CODE" "NV_FLUSH_CACHE_ALL_PRESENT" "" "functions"
        ;;

        pci_get_domain_bus_and_slot)
            #
            # Determine if the pci_get_domain_bus_and_slot() function
            # is present.
            #
            # Added by commit 3c299dc22635 ("PCI: add
            # pci_get_domain_bus_and_slot function") in 2.6.33 but aarch64
            # support was added by commit d1e6dc91b532 
            # ("arm64: Add architectural support for PCI") in 3.18-rc1
            #
            CODE="
            #include <linux/pci.h>
            void conftest_pci_get_domain_bus_and_slot(void) {
                pci_get_domain_bus_and_slot();
            }"

            compile_check_conftest "$CODE" "NV_PCI_GET_DOMAIN_BUS_AND_SLOT_PRESENT" "" "functions"
        ;;

        pci_bus_address)
            #
            # Determine if the pci_bus_address() function is
            # present.
            #
            # Added by commit 06cf56e497c8 ("PCI: Add pci_bus_address() to
            # get bus address of a BAR") in v3.14
            #
            CODE="
            #include <linux/pci.h>
            void conftest_pci_bus_address(void) {
                pci_bus_address();
            }"

            compile_check_conftest "$CODE" "NV_PCI_BUS_ADDRESS_PRESENT" "" "functions"
        ;;

        hash__remap_4k_pfn)
            #
            # Determine if the hash__remap_4k_pfn() function is
            # present.
            #
            # Added by commit 6cc1a0ee4ce2 ("powerpc/mm/radix: Add radix
            # callback for pmd accessors") in v4.7 (committed 2016-04-29).
            # Present only in arch/powerpc
            #
            CODE="
            #if defined(NV_ASM_BOOK3S_64_HASH_64K_H_PRESENT)
            #include <linux/mm.h>
            #include <asm/book3s/64/hash-64k.h>
            #endif
            void conftest_hash__remap_4k_pfn(void) {
                hash__remap_4k_pfn();
            }"

            compile_check_conftest "$CODE" "NV_HASH__REMAP_4K_PFN_PRESENT" "" "functions"
        ;;

        register_cpu_notifier)
            #
            # Determine if register_cpu_notifier() is present
            #
            # Removed by commit 530e9b76ae8f ("cpu/hotplug: Remove obsolete
            # cpu hotplug register/unregister functions") in v4.10
            # (2016-12-21)
            #
            CODE="
            #include <linux/cpu.h>
            void conftest_register_cpu_notifier(void) {
                register_cpu_notifier();
            }"
            compile_check_conftest "$CODE" "NV_REGISTER_CPU_NOTIFIER_PRESENT" "" "functions"
        ;;

        cpuhp_setup_state)
            #
            # Determine if cpuhp_setup_state() is present
            #
            # Added by commit 5b7aa87e0482 ("cpu/hotplug: Implement
            # setup/removal interface") in v4.6 (commited 2016-02-26)
            #
            # It is used as a replacement for register_cpu_notifier
            CODE="
            #include <linux/cpu.h>
            void conftest_cpuhp_setup_state(void) {
                cpuhp_setup_state();
            }"
            compile_check_conftest "$CODE" "NV_CPUHP_SETUP_STATE_PRESENT" "" "functions"
        ;;

        ioremap_cache)
            #
            # Determine if the ioremap_cache() function is present.
            # It does not exist on all architectures.
            #
            CODE="
            #include <asm/io.h>
            void conftest_ioremap_cache(void) {
                ioremap_cache();
            }"

            compile_check_conftest "$CODE" "NV_IOREMAP_CACHE_PRESENT" "" "functions"
        ;;

        ioremap_wc)
            #
            # Determine if the ioremap_wc() function is present.
            # It does not exist on all architectures.
            #
            CODE="
            #include <asm/io.h>
            void conftest_ioremap_wc(void) {
                ioremap_wc();
            }"

            compile_check_conftest "$CODE" "NV_IOREMAP_WC_PRESENT" "" "functions"
        ;;

        ioremap_driver_hardened)
            #
            # Determine if the ioremap_driver_hardened() function is present.
            # It does not exist on all architectures.
            # TODO: Update the commit ID once the API is upstreamed.
            #
            CODE="
            #include <asm/io.h>
            void conftest_ioremap_driver_hardened(void) {
                ioremap_driver_hardened();
            }"

            compile_check_conftest "$CODE" "NV_IOREMAP_DRIVER_HARDENED_PRESENT" "" "functions"
        ;;

        ioremap_driver_hardened_wc)
            #
            # Determine if the ioremap_driver_hardened_wc() function is present.
            # It does not exist on all architectures.
            # TODO: Update the commit ID once the API is upstreamed.
            #
            CODE="
            #include <asm/io.h>
            void conftest_ioremap_driver_hardened_wc(void) {
                ioremap_driver_hardened_wc();
            }"

            compile_check_conftest "$CODE" "NV_IOREMAP_DRIVER_HARDENED_WC_PRESENT" "" "functions"
        ;;

        ioremap_cache_shared)
            #
            # Determine if the ioremap_cache_shared() function is present.
            # It does not exist on all architectures.
            # TODO: Update the commit ID once the API is upstreamed.
            #
            CODE="
            #include <asm/io.h>
            void conftest_ioremap_cache_shared(void) {
                ioremap_cache_shared();
            }"

            compile_check_conftest "$CODE" "NV_IOREMAP_CACHE_SHARED_PRESENT" "" "functions"
        ;;
        dom0_kernel_present)
            # Add config parameter if running on DOM0.
            if [ -n "$VGX_BUILD" ]; then
                echo "#define NV_DOM0_KERNEL_PRESENT" | append_conftest "generic"
            else
                echo "#undef NV_DOM0_KERNEL_PRESENT" | append_conftest "generic"
            fi
            return
        ;;

        nvidia_vgpu_kvm_build)
           # Add config parameter if running on KVM host.
           if [ -n "$VGX_KVM_BUILD" ]; then
                echo "#define NV_VGPU_KVM_BUILD" | append_conftest "generic"
            else
                echo "#undef NV_VGPU_KVM_BUILD" | append_conftest "generic"
            fi
            return
        ;;

        vfio_register_notifier)
            #
            # Check number of arguments required.
            #
            # New parameters added by commit 22195cbd3451 ("vfio:
            # vfio_register_notifier: classify iommu notifier") in v4.10
            #
            echo "$CONFTEST_PREAMBLE
            #include <linux/vfio.h>
            int conftest_vfio_register_notifier(void) {
                return vfio_register_notifier((struct device *) NULL, (struct notifier_block *) NULL);
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                echo "#define NV_VFIO_NOTIFIER_ARGUMENT_COUNT 2" | append_conftest "functions"
                rm -f conftest$$.o
                return
            else
                echo "#define NV_VFIO_NOTIFIER_ARGUMENT_COUNT 4" | append_conftest "functions"
                return
            fi
        ;;

        vfio_info_add_capability_has_cap_type_id_arg)
            #
            # Check if vfio_info_add_capability() has cap_type_id parameter.
            #
            # Removed by commit dda01f787df9 ("vfio: Simplify capability
            # helper") in v4.16 (2017-12-12)
            #
            CODE="
            #include <linux/vfio.h>
            int vfio_info_add_capability(struct vfio_info_cap *caps,
                                         int cap_type_id,
                                         void *cap_type) {
                return 0;
            }"

            compile_check_conftest "$CODE" "NV_VFIO_INFO_ADD_CAPABILITY_HAS_CAP_TYPE_ID_ARGS" "" "types"
        ;;

        nvidia_grid_build)
            if [ -n "$GRID_BUILD" ]; then
                echo "#define NV_GRID_BUILD" | append_conftest "generic"
            else
                echo "#undef NV_GRID_BUILD" | append_conftest "generic"
            fi
            return
        ;;

        nvidia_grid_csp_build)
            if [ -n "$GRID_BUILD_CSP" ]; then
                echo "#define NV_GRID_BUILD_CSP $GRID_BUILD_CSP" | append_conftest "generic"
            else
                echo "#undef NV_GRID_BUILD_CSP" | append_conftest "generic"
            fi
            return
        ;;

        vm_fault_has_address)
            #
            # Determine if the 'vm_fault' structure has an 'address', or a
            # 'virtual_address' field. The .virtual_address field was
            # effectively renamed to .address:
            #
            # 'address' added by commit 82b0f8c39a38 ("mm: join
            # struct fault_env and vm_fault") in v4.10 (2016-12-14)
            #
            # 'virtual_address' removed by commit 1a29d85eb0f1 ("mm: use
            # vmf->address instead of of vmf->virtual_address") in v4.10
            # (2016-12-14)
            #
            CODE="
            #include <linux/mm.h>
            int conftest_vm_fault_has_address(void) {
                return offsetof(struct vm_fault, address);
            }"

            compile_check_conftest "$CODE" "NV_VM_FAULT_HAS_ADDRESS" "" "types"
        ;;

        kmem_cache_has_kobj_remove_work)
            #
            # Determine if the 'kmem_cache' structure has 'kobj_remove_work'.
            #
            # 'kobj_remove_work' was added by commit 3b7b314053d02 ("slub: make
            # sysfs file removal asynchronous") in v4.12 (2017-06-23). This
            # commit introduced a race between kmem_cache destroy and create
            # which we need to workaround in our driver (see nvbug: 2543505).
            # Also see comment for sysfs_slab_unlink conftest.
            #
            CODE="
            #include <linux/mm.h>
            #include <linux/slab.h>
            #include <linux/slub_def.h>
            int conftest_kmem_cache_has_kobj_remove_work(void) {
                return offsetof(struct kmem_cache, kobj_remove_work);
            }"

            compile_check_conftest "$CODE" "NV_KMEM_CACHE_HAS_KOBJ_REMOVE_WORK" "" "types"
        ;;

        mdev_uuid)
            #
            # Determine if mdev_uuid() function is present or not
            #
            # Added by commit 99e3123e3d72 ("vfio-mdev: Make mdev_device
            # private and abstract interfaces") in v4.10
            #
            CODE="
            #include <linux/pci.h>
            #include <linux/mdev.h>
            void conftest_mdev_uuid() {
                mdev_uuid();
            }"

            compile_check_conftest "$CODE" "NV_MDEV_UUID_PRESENT" "" "functions"

            #
            # Determine if mdev_uuid() returns 'const guid_t *'.
            #
            # mdev_uuid() function prototype updated to return 'const guid_t *'
            # by commit 278bca7f318e ("vfio-mdev: Switch to use new generic UUID
            # API") in v5.1 (2019-01-10).
            #
            CODE="
            #include <linux/pci.h>
            #include <linux/mdev.h>
            const guid_t *conftest_mdev_uuid_return_guid_ptr(struct mdev_device *mdev) {
                return mdev_uuid(mdev);
            }"

            compile_check_conftest "$CODE" "NV_MDEV_UUID_RETURN_GUID_PTR" "" "types"
        ;;

        mdev_dev)
            #
            # Determine if mdev_dev() function is present or not
            #
            # Added by commit 99e3123e3d72 ("vfio-mdev: Make mdev_device
            # private and abstract interfaces") in v4.10
            #
            CODE="
            #include <linux/pci.h>
            #include <linux/mdev.h>
            void conftest_mdev_dev() {
                mdev_dev();
            }"

            compile_check_conftest "$CODE" "NV_MDEV_DEV_PRESENT" "" "functions"
        ;;

        mdev_get_type_group_id)
            #
            # Determine if mdev_get_type_group_id() function is present or not
            #
            # Added by commit 15fcc44be0c7a ("vfio/mdev: Add
            # mdev/mtype_get_type_group_id()") in v5.13
            #
            CODE="
            #include <linux/pci.h>
            #include <linux/mdev.h>
            void conftest_mdev_get_type_group_id() {
                mdev_get_type_group_id();
            }"

            compile_check_conftest "$CODE" "NV_MDEV_GET_TYPE_GROUP_ID_PRESENT" "" "functions"
        ;;

        vfio_device_mig_state)
            #
            # Determine if vfio_device_mig_state enum is present or not
            #
            # Added by commit 115dcec65f61d ("vfio: Define device
            # migration protocol v2") in v5.18
            #
            CODE="
            #include <linux/pci.h>
            #include <linux/vfio.h>
            enum vfio_device_mig_state device_state;
            "

            compile_check_conftest "$CODE" "NV_VFIO_DEVICE_MIG_STATE_PRESENT" "" "types"
        ;;

        vfio_migration_ops)
            #
            # Determine if vfio_migration_ops struct is present or not
            #
            # Added by commit 6e97eba8ad874 ("vfio: Split migration ops
            # from main device ops") in v6.0
            #
            CODE="
            #include <linux/pci.h>
            #include <linux/vfio.h>
            struct vfio_migration_ops mig_ops;
            "

            compile_check_conftest "$CODE" "NV_VFIO_MIGRATION_OPS_PRESENT" "" "types"
        ;;

        vfio_precopy_info)
            #
            # Determine if vfio_precopy_info struct is present or not
            #
            # Added by commit 4db52602a6074 ("vfio: Extend the device migration
            # protocol with PRE_COPY" in v6.2
            #
            CODE="
            #include <linux/vfio.h>
            struct vfio_precopy_info precopy_info;
            "

            compile_check_conftest "$CODE" "NV_VFIO_PRECOPY_INFO_PRESENT" "" "types"
        ;;

        vfio_log_ops)
            #
            # Determine if vfio_log_ops struct is present or not
            #
            # Added by commit 80c4b92a2dc48 ("vfio: Introduce the DMA
            # logging feature support") in v6.1
            #
            CODE="
            #include <linux/pci.h>
            #include <linux/vfio.h>
            struct vfio_log_ops log_ops;
            "

            compile_check_conftest "$CODE" "NV_VFIO_LOG_OPS_PRESENT" "" "types"
        ;;

        vfio_migration_ops_has_migration_get_data_size)
            #
            # Determine if vfio_migration_ops struct has .migration_get_data_size field.
            #
            # Added by commit in 4e016f969529f ("vfio: Add an option to get migration 
            # data size") in v6.2 kernel.
            #
            CODE="
            #include <linux/pci.h>
            #include <linux/vfio.h>
            int conftest_mdev_vfio_migration_ops_has_migration_get_data_size(void) {
                return offsetof(struct vfio_migration_ops, migration_get_data_size);
            }"

            compile_check_conftest "$CODE" "NV_VFIO_MIGRATION_OPS_HAS_MIGRATION_GET_DATA_SIZE" "" "types"
        ;;

        mdev_parent_ops)
            #
            # Determine if the struct mdev_parent_ops type is present.
            #
            # Added by commit 42930553a7c1 ("vfio-mdev: de-polute the
            # namespace, rename parent_device & parent_ops") in v4.10
            #
            CODE="
            #include <linux/pci.h>
            #include <linux/mdev.h>
            struct mdev_parent_ops conftest_mdev_parent_ops;
            "

            compile_check_conftest "$CODE" "NV_MDEV_PARENT_OPS_STRUCT_PRESENT" "" "types"
        ;;

        mdev_parent)
            #
            # Determine if the struct mdev_parent type is present.
            #
            # Added by commit 89345d5177aa ("vfio/mdev: embedd struct mdev_parent in
            # the parent data structure") in v6.1
            #
            CODE="
            #include <linux/pci.h>
            #include <linux/mdev.h>
            struct mdev_parent conftest_mdev_parent;
            "

            compile_check_conftest "$CODE" "NV_MDEV_PARENT_STRUCT_PRESENT" "" "types"
        ;;

        mdev_parent_dev)
            #
            # Determine if mdev_parent_dev() function is present or not
            #
            # Added by commit 9372e6feaafb ("vfio-mdev: Make mdev_parent
            # private") in v4.10
            #
            CODE="
            #include <linux/pci.h>
            #include <linux/mdev.h>
            void conftest_mdev_parent_dev() {
                mdev_parent_dev();
            }"

            compile_check_conftest "$CODE" "NV_MDEV_PARENT_DEV_PRESENT" "" "functions"
        ;;

        vfio_free_device)
            #
            # Determine if vfio_free_device() function is present or not
            #
            # Removed by commit 913447d06f03 ("vfio: Remove vfio_free_device")
            # in v6.2
            #
            CODE="
            #include <linux/pci.h>
            #include <linux/vfio.h>
            void conftest_vfio_free_device() {
                vfio_free_device();
            }"

            compile_check_conftest "$CODE" "NV_VFIO_FREE_DEVICE_PRESENT" "" "functions"
        ;;

        mdev_from_dev)
            #
            # Determine if mdev_from_dev() function is present or not.
            #
            # Added by commit 99e3123e3d72 ("vfio-mdev: Make mdev_device
            # private and abstract interfaces") in v4.10 (2016-12-30)
            #
            CODE="
            #include <linux/pci.h>
            #include <linux/mdev.h>
            void conftest_mdev_from_dev() {
                mdev_from_dev();
            }"

            compile_check_conftest "$CODE" "NV_MDEV_FROM_DEV_PRESENT" "" "functions"
        ;;

        mdev_set_iommu_device)
            #
            # Determine if mdev_set_iommu_device() function is present or not.
            #
            # Added by commit 8ac13175cbe9 ("vfio/mdev: Add iommu related member
            # in mdev_device) in v5.1 (2019-04-12)
            #
            CODE="
            #include <linux/pci.h>
            #include <linux/mdev.h>
            void conftest_mdev_set_iommu_device() {
                mdev_set_iommu_device();
            }"

            compile_check_conftest "$CODE" "NV_MDEV_SET_IOMMU_DEVICE_PRESENT" "" "functions"
        ;;

        mdev_parent_ops_has_open_device)
            # Determine if 'mdev_parent_ops' structure has a 'open_device'
            # field.
            #
            # Added by commit 2fd585f4ed9d ("vfio: Provide better generic support
            # for open/release vfio_device_ops") in 5.15 (2021-08-05)
            #
            CODE="
            #include <linux/pci.h>
            #include <linux/mdev.h>
            int conftest_mdev_parent_ops_has_open_device(void) {
                return offsetof(struct mdev_parent_ops, open_device);
            }"

            compile_check_conftest "$CODE" "NV_MDEV_PARENT_OPS_HAS_OPEN_DEVICE" "" "types"
        ;;

        mdev_parent_ops_has_device_driver)
            #
            # Determine if 'mdev_parent_ops' structure has 'device_driver' field.
            #
            # Added by commit 88a21f265ce5 ("vfio/mdev: Allow the mdev_parent_ops
            # to specify the device driver to bind) in v5.14 (2021-06-17)
            #
            CODE="
            #include <linux/pci.h>
            #include <linux/mdev.h>
            int conftest_mdev_parent_ops_has_device_driver(void) {
                return offsetof(struct mdev_parent_ops, device_driver);
            }"

            compile_check_conftest "$CODE" "NV_MDEV_PARENT_OPS_HAS_DEVICE_DRIVER" "" "types"
        ;;

        mdev_driver_has_supported_type_groups)
            #
            # Determine if 'mdev_driver' structure has 'supported_type_groups' field.
            #
            # Added by commit 6b42f491e17c ("vfio/mdev: Remove mdev_parent_ops)
            # in v5.19 (2022-04-11)
            #
            CODE="
            #include <linux/pci.h>
            #include <linux/mdev.h>
            int conftest_mdev_driver_has_supported_type_groups(void) {
                return offsetof(struct mdev_driver, supported_type_groups);
            }"

            compile_check_conftest "$CODE" "NV_MDEV_DRIVER_HAS_SUPPORTED_TYPE_GROUPS" "" "types"
        ;;

        vfio_device_ops_has_dma_unmap)
            #
            # Determine if 'vfio_device_ops' struct has 'dma_unmap' field.
            #
            # Added by commit ce4b4657ff18 ("vfio: Replace the DMA unmapping
            # notifier with a callback") in v6.0
            #
            CODE="
            #include <linux/pci.h>
            #include <linux/vfio.h>
            int conftest_vfio_device_ops_has_dma_unmap(void) {
                return offsetof(struct vfio_device_ops, dma_unmap);
            }"

            compile_check_conftest "$CODE" "NV_VFIO_DEVICE_OPS_HAS_DMA_UNMAP" "" "types"
        ;;

        pci_irq_vector_helpers)
            #
            # Determine if pci_alloc_irq_vectors(), pci_free_irq_vectors()
            # functions are present or not.
            #
            # Added by commit aff171641d181ea573 (PCI: Provide sensible IRQ
            # vector alloc/free routines) (2016-07-12)
            #
            CODE="
            #include <linux/pci.h>
            #include <linux/msi.h>
            void conftest_pci_irq_vector_helpers() {
                pci_alloc_irq_vectors();
                pci_free_irq_vectors ();
            }"

            compile_check_conftest "$CODE" "NV_PCI_IRQ_VECTOR_HELPERS_PRESENT" "" "functions"
        ;;


        vfio_device_gfx_plane_info)
            #
            # determine if the 'struct vfio_device_gfx_plane_info' type is present.
            #
            # Added by commit e20eaa2382e7 ("vfio: ABI for mdev display
            # dma-buf operation") in v4.16 (2017-11-23)
            #
            CODE="
            #include <linux/vfio.h>
            struct vfio_device_gfx_plane_info info;"

            compile_check_conftest "$CODE" "NV_VFIO_DEVICE_GFX_PLANE_INFO_PRESENT" "" "types"
        ;;

        vfio_device_migration_has_start_pfn)
            #
            # Determine if the 'vfio_device_migration_info' structure has
            # a 'start_pfn' field.
            #
            # This member was present in proposed interface for vGPU Migration
            # ("[PATCH v3 0/5] Add migration support for VFIO device ")
            # https://lists.gnu.org/archive/html/qemu-devel/2019-02/msg05176.html
            # which is not present in upstreamed commit a8a24f3f6e38 (vfio: UAPI
            # for migration interface for device state) in v5.8 (2020-05-29)
            #
            CODE="
            #include <linux/vfio.h>
            int conftest_vfio_device_migration_has_start_pfn(void) {
                return offsetof(struct vfio_device_migration_info, start_pfn);
            }"

            compile_check_conftest "$CODE" "NV_VFIO_DEVICE_MIGRATION_HAS_START_PFN" "" "types"
        ;;

        vfio_uninit_group_dev)
            #
            # Determine if vfio_uninit_group_dev() function is present or not.
            #
            # Added by commit ae03c3771b8c (vfio: Introduce a vfio_uninit_group_dev()
            # API call) in v5.15
            #
            CODE="
            #include <linux/vfio.h>
            void conftest_vfio_uninit_group_dev() {
                vfio_uninit_group_dev();
            }"

            compile_check_conftest "$CODE" "NV_VFIO_UNINIT_GROUP_DEV_PRESENT" "" "functions"
        ;;

        vfio_pci_core_available)
            # Determine if VFIO_PCI_CORE is available
            #
            # Added by commit 7fa005caa35e ("vfio/pci: Introduce
            # vfio_pci_core.ko") in v5.16 (2021-08-26)
            #

            CODE="
            #if defined(NV_LINUX_VFIO_PCI_CORE_H_PRESENT)
            #include <linux/vfio_pci_core.h>
            #endif

            #if !defined(CONFIG_VFIO_PCI_CORE) && !defined(CONFIG_VFIO_PCI_CORE_MODULE)
            #error VFIO_PCI_CORE not enabled
            #endif
            void conftest_vfio_pci_core_available(void) {
                struct vfio_pci_core_device dev;
            }"

            compile_check_conftest "$CODE" "NV_VFIO_PCI_CORE_PRESENT" "" "generic"
        ;;

        mdev_available)
            # Determine if MDEV is available
            #
            # Added by commit 7b96953bc640 ("vfio: Mediated device Core driver")
            # in v4.10
            #
            CODE="
            #if defined(NV_LINUX_MDEV_H_PRESENT)
            #include <linux/pci.h>
            #include <linux/mdev.h>
            #endif

            #if !defined(CONFIG_VFIO_MDEV) && !defined(CONFIG_VFIO_MDEV_MODULE)
            #error MDEV not enabled
            #endif
            void conftest_mdev_available(void) {
                struct mdev_device *mdev;
            }"

            compile_check_conftest "$CODE" "NV_MDEV_PRESENT" "" "generic"
        ;;

        vfio_alloc_device)
            #
            # Determine if vfio_alloc_device() function is present or not.
            #
            # Added by commit cb9ff3f3b84c (vfio: Add helpers for unifying vfio_device
            # life cycle) in v6.1
            #
            CODE="
            #include <linux/vfio.h>
            void conftest_vfio_alloc_device() {
                vfio_alloc_device();
            }"

            compile_check_conftest "$CODE" "NV_VFIO_ALLOC_DEVICE_PRESENT" "" "functions"
        ;;

        vfio_register_emulated_iommu_dev)
            #
            # Determine if vfio_register_emulated_iommu_dev() function is present or not.
            #
            # Added by commit c68ea0d00ad8 (vfio: simplify iommu group allocation
            # for mediated devices) in v5.16
            #
            CODE="
            #include <linux/vfio.h>
            void conftest_vfio_register_emulated_iommu_dev() {
                vfio_register_emulated_iommu_dev();
            }"

            compile_check_conftest "$CODE" "NV_VFIO_REGISTER_EMULATED_IOMMU_DEV_PRESENT" "" "functions"
        ;;

        drm_available)
            # Determine if the DRM subsystem is usable
            CODE="
            #if defined(NV_DRM_DRMP_H_PRESENT)
            #include <drm/drmP.h>
            #endif

            #if defined(NV_DRM_DRM_DRV_H_PRESENT)
            #include <drm/drm_drv.h>
            #endif

            #if !defined(CONFIG_DRM) && !defined(CONFIG_DRM_MODULE)
            #error DRM not enabled
            #endif

            void conftest_drm_available(void) {
                struct drm_driver drv;

                /* 2013-10-02 1bb72532ac260a2d3982b40bdd4c936d779d0d16 */
                (void)drm_dev_alloc;

                /* 2013-10-02 c22f0ace1926da399d9a16dfaf09174c1b03594c */
                (void)drm_dev_register;

                /* 2013-10-02 c3a49737ef7db0bdd4fcf6cf0b7140a883e32b2a */
                (void)drm_dev_unregister;
            }"

            compile_check_conftest "$CODE" "NV_DRM_AVAILABLE" "" "generic"
        ;;

        drm_dev_unref)
            #
            # Determine if drm_dev_unref() is present.
            # If it isn't, we use drm_dev_free() instead.
            #
            # drm_dev_free was added by commit 0dc8fe5985e0 ("drm: introduce
            # drm_dev_free() to fix error paths") in v3.13 (2013-10-02)
            #
            # Renamed to drm_dev_unref by commit 099d1c290e2e
            # ("drm: provide device-refcount") in v3.15 (2014-01-29)
            #
            CODE="
            #if defined(NV_DRM_DRMP_H_PRESENT)
            #include <drm/drmP.h>
            #endif
            void conftest_drm_dev_unref(void) {
                drm_dev_unref();
            }"

            compile_check_conftest "$CODE" "NV_DRM_DEV_UNREF_PRESENT" "" "functions"
        ;;

        pde_data)
            #
            # Determine if the pde_data() function is present.
            #
            # The commit c28198889c15 removed the function
            # 'PDE_DATA()', and replaced it with 'pde_data()'
            # ("proc: remove PDE_DATA() completely") in v5.17-rc1.
            #
            CODE="
            #include <linux/proc_fs.h>
            void conftest_pde_data(void) {
                pde_data();
            }"

            compile_check_conftest "$CODE" "NV_PDE_DATA_LOWER_CASE_PRESENT" "" "functions"
        ;;

        get_num_physpages)
            #
            # Determine if the get_num_physpages() function is
            # present.
            #
            # Added by commit 7ee3d4e8cd56 ("mm: introduce helper function
            # mem_init_print_info() to simplify mem_init()") in v3.11
            #
            CODE="
            #include <linux/mm.h>
            void conftest_get_num_physpages(void) {
                get_num_physpages(NULL);
            }"

            compile_check_conftest "$CODE" "NV_GET_NUM_PHYSPAGES_PRESENT" "" "functions"
        ;;

        backing_dev_info)
            #
            # Determine if the 'address_space' structure has
            # a 'backing_dev_info' field.
            #
            # Removed by commit b83ae6d42143 ("fs: remove
            # mapping->backing_dev_info") in v4.0
            #
            CODE="
            #include <linux/fs.h>
            int conftest_backing_dev_info(void) {
                return offsetof(struct address_space, backing_dev_info);
            }"

            compile_check_conftest "$CODE" "NV_ADDRESS_SPACE_HAS_BACKING_DEV_INFO" "" "types"
        ;;

        xen_ioemu_inject_msi)
            # Determine if the xen_ioemu_inject_msi() function is present.
            CODE="
            #if defined(NV_XEN_IOEMU_H_PRESENT)
            #include <linux/kernel.h>
            #include <xen/interface/xen.h>
            #include <xen/hvm.h>
            #include <xen/ioemu.h>
            #endif
            void conftest_xen_ioemu_inject_msi(void) {
                xen_ioemu_inject_msi();
            }"

            compile_check_conftest "$CODE" "NV_XEN_IOEMU_INJECT_MSI" "" "functions"
        ;;

        phys_to_dma)
            #
            # Determine if the phys_to_dma function is present.
            # It does not exist on all architectures.
            #
            CODE="
            #include <linux/dma-mapping.h>
            void conftest_phys_to_dma(void) {
                phys_to_dma();
            }"

            compile_check_conftest "$CODE" "NV_PHYS_TO_DMA_PRESENT" "" "functions"
        ;;


        dma_attr_macros)
           #
           # Determine if the NV_DMA_ATTR_SKIP_CPU_SYNC_PRESENT macro present.
           # It does not exist on all architectures.
           #
           CODE="
           #include <linux/dma-mapping.h>
           void conftest_dma_attr_macros(void) {
               int ret;
               ret = DMA_ATTR_SKIP_CPU_SYNC();
           }"
           compile_check_conftest "$CODE" "NV_DMA_ATTR_SKIP_CPU_SYNC_PRESENT" "" "functions"
        ;;

       dma_map_page_attrs)
           #
           # Determine if the dma_map_page_attrs function is present.
           # It does not exist on all architectures.
           #
           CODE="
           #include <linux/dma-mapping.h>
           void conftest_dma_map_page_attrs(void) {
               dma_map_page_attrs();
           }"

           compile_check_conftest "$CODE" "NV_DMA_MAP_PAGE_ATTRS_PRESENT" "" "functions"
        ;;

        dma_ops)
            #
            # Determine if the 'dma_ops' structure is present.
            # It does not exist on all architectures.
            #
            CODE="
            #include <linux/dma-mapping.h>
            void conftest_dma_ops(void) {
                (void)dma_ops;
            }"

            compile_check_conftest "$CODE" "NV_DMA_OPS_PRESENT" "" "symbols"
        ;;

        swiotlb_dma_ops)
            #
            # Determine if the 'swiotlb_dma_ops' structure is present.
            # It does not exist on all architectures.
            #
            CODE="
            #include <linux/dma-mapping.h>
            void conftest_dma_ops(void) {
                (void)swiotlb_dma_ops;
            }"

            compile_check_conftest "$CODE" "NV_SWIOTLB_DMA_OPS_PRESENT" "" "symbols"
        ;;

        get_dma_ops)
            #
            # Determine if the get_dma_ops() function is present.
            #
            # The structure was made available to all architectures by commit
            # e1c7e324539a ("dma-mapping: always provide the dma_map_ops
            # based implementation") in v4.5
            #
            # Commit 0a0f0d8be76d ("dma-mapping: split <linux/dma-mapping.h>")
            # in v5.10-rc1 (2020-09-22), moved get_dma_ops() function
            # prototype from <linux/dma-mapping.h> to <linux/dma-map-ops.h>.
            #
            CODE="
            #if defined(NV_LINUX_DMA_MAP_OPS_H_PRESENT)
            #include <linux/dma-map-ops.h>
            #else
            #include <linux/dma-mapping.h>
            #endif
            void conftest_get_dma_ops(void) {
                get_dma_ops();
            }"

            compile_check_conftest "$CODE" "NV_GET_DMA_OPS_PRESENT" "" "functions"
        ;;

        noncoherent_swiotlb_dma_ops)
            #
            # Determine if the 'noncoherent_swiotlb_dma_ops' symbol is present.
            # This API only exists on ARM64.
            #
            # Added by commit 7363590d2c46 ("arm64: Implement coherent DMA API
            # based on swiotlb") in v3.15
            #
            # Removed by commit 9d3bfbb4df58 ("arm64: Combine coherent and
            # non-coherent swiotlb dma_ops") in v4.0
            #
            CODE="
            #include <linux/dma-mapping.h>
            void conftest_noncoherent_swiotlb_dma_ops(void) {
                (void)noncoherent_swiotlb_dma_ops;
            }"

            compile_check_conftest "$CODE" "NV_NONCOHERENT_SWIOTLB_DMA_OPS_PRESENT" "" "symbols"
        ;;

        dma_map_resource)
            #
            # Determine if the dma_map_resource() function is present.
            #
            # Added by commit 6f3d87968f9c ("dma-mapping: add
            # dma_{map,unmap}_resource") in v4.9 (2016-08-10)
            #
            CODE="
            #include <linux/dma-mapping.h>
            void conftest_dma_map_resource(void) {
                dma_map_resource();
            }"

            compile_check_conftest "$CODE" "NV_DMA_MAP_RESOURCE_PRESENT" "" "functions"
        ;;

        write_cr4)
            #
            # Determine if the write_cr4() function is present.
            #
            CODE="
            #include <asm/processor.h>
            void conftest_write_cr4(void) {
                write_cr4();
            }"

            compile_check_conftest "$CODE" "NV_WRITE_CR4_PRESENT" "" "functions"
        ;;

       nvhost_dma_fence_unpack)
           #
           # Determine if the nvhost_dma_fence_unpack function is present.
           # This is only present in NVIDIA Tegra downstream kernels.
           #
           CODE="
           #if defined(NV_LINUX_NVHOST_H_PRESENT)
           #include <linux/nvhost.h>
           #endif
           void conftest_nvhost_dma_fence_unpack(void) {
               nvhost_dma_fence_unpack();
           }"

           compile_check_conftest "$CODE" "NV_NVHOST_DMA_FENCE_UNPACK_PRESENT" "" "functions"
        ;;

        of_find_node_by_phandle)
            #
            # Determine if the of_find_node_by_phandle function is present.
            #
            # Support for kernels without CONFIG_OF defined added by commit
            # ce16b9d23561 ("of: define of_find_node_by_phandle for
            # !CONFIG_OF") in v4.2
            #
            # Test if linux/of.h header file inclusion is successful or not and
            # define/undefine NV_LINUX_OF_H_USABLE depending upon status of inclusion.
            #
            echo "$CONFTEST_PREAMBLE
            #include <linux/of.h>
            " > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                rm -f conftest$$.o
                echo "#define NV_LINUX_OF_H_USABLE" | append_conftest "generic"
                CODE="
                #include <linux/of.h>
                void conftest_of_find_node_by_phandle() {
                    of_find_node_by_phandle();
                }"

                compile_check_conftest "$CODE" "NV_OF_FIND_NODE_BY_PHANDLE_PRESENT" "" "functions"
            else
                echo "#undef NV_LINUX_OF_H_USABLE" | append_conftest "generic"
                echo "#undef NV_OF_FIND_NODE_BY_PHANDLE_PRESENT" | append_conftest "functions"
            fi
        ;;

        of_node_to_nid)
            #
            # Determine if of_node_to_nid is present
            #
            # Dummy implementation added by commit 559e2b7ee7a1
            # ("of: Provide default of_node_to_nid() implementation.") in v2.6.36
            #
            # Real implementation added by commit 298535c00a2c
            # ("of, numa: Add NUMA of binding implementation.") in v4.7
            #
            # Test if linux/of.h header file inclusion is successful or not and
            # define/undefine NV_LINUX_OF_H_USABLE depending upon status of inclusion.
            #
            echo "$CONFTEST_PREAMBLE
            #include <linux/of.h>
            " > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                rm -f conftest$$.o
                echo "#define NV_LINUX_OF_H_USABLE" | append_conftest "generic"
                CODE="
                #include <linux/version.h>
                #include <linux/utsname.h>
                #include <linux/of.h>
                void conftest_of_node_to_nid() {
                    of_node_to_nid();
                }"

                compile_check_conftest "$CODE" "NV_OF_NODE_TO_NID_PRESENT" "" "functions"
            else
                echo "#undef NV_LINUX_OF_H_USABLE" | append_conftest "generic"
                echo "#undef NV_OF_NODE_TO_NID_PRESENT" | append_conftest "functions"
            fi
        ;;

        pnv_pci_get_npu_dev)
            #
            # Determine if the pnv_pci_get_npu_dev function is present.
            #
            # Added by commit 5d2aa710e697 ("powerpc/powernv: Add support
            # for Nvlink NPUs") in v4.5
            #
            CODE="
            #include <linux/pci.h>
            void conftest_pnv_pci_get_npu_dev() {
                pnv_pci_get_npu_dev();
            }"

            compile_check_conftest "$CODE" "NV_PNV_PCI_GET_NPU_DEV_PRESENT" "" "functions"
        ;;

        kernel_write_has_pointer_pos_arg)
            #
            # Determine the pos argument type, which was changed by
            # commit e13ec939e96b1 (fs: fix kernel_write prototype) on
            # 9/1/2017.
            #
            echo "$CONFTEST_PREAMBLE
            #include <linux/fs.h>
            ssize_t kernel_write(struct file *file, const void *buf,
                                 size_t count, loff_t *pos)
            {
                return 0;
            }" > conftest$$.c;

	    $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

	    if [ -f conftest$$.o ]; then
                echo "#define NV_KERNEL_WRITE_HAS_POINTER_POS_ARG" | append_conftest "function"
                rm -f conftest$$.o
            else
                echo "#undef NV_KERNEL_WRITE_HAS_POINTER_POS_ARG" | append_conftest "function"
            fi
        ;;

        kernel_read_has_pointer_pos_arg)
            #
            # Determine the pos argument type, which was changed by
            # commit bdd1d2d3d251c (fs: fix kernel_read prototype) on
            # 9/1/2017.
            #
            echo "$CONFTEST_PREAMBLE
            #include <linux/fs.h>
            ssize_t kernel_read(struct file *file, void *buf, size_t count,
                                loff_t *pos)
            {
                return 0;
            }" > conftest$$.c;

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                echo "#define NV_KERNEL_READ_HAS_POINTER_POS_ARG" | append_conftest "function"
                rm -f conftest$$.o
            else
                echo "#undef NV_KERNEL_READ_HAS_POINTER_POS_ARG" | append_conftest "function"
            fi
        ;;

        vm_insert_pfn_prot)
            #
            # Determine if vm_insert_pfn_prot function is present
            #
            # Added by commit 1745cbc5d0de ("mm: Add vm_insert_pfn_prot()") in
            # v3.16.59
            #
            # Removed by commit f5e6d1d5f8f3 ("mm: introduce
            # vmf_insert_pfn_prot()") in v4.20.
            #
            CODE="
            #include <linux/mm.h>
            void conftest_vm_insert_pfn_prot() {
                vm_insert_pfn_prot();
            }"

            compile_check_conftest "$CODE" "NV_VM_INSERT_PFN_PROT_PRESENT" "" "functions"
        ;;

        vmf_insert_pfn_prot)
            #
            # Determine if vmf_insert_pfn_prot function is present
            #
            # Added by commit f5e6d1d5f8f3 ("mm: introduce
            # vmf_insert_pfn_prot()") in v4.20.
            #
            CODE="
            #include <linux/mm.h>
            void conftest_vmf_insert_pfn_prot() {
                vmf_insert_pfn_prot();
            }"

            compile_check_conftest "$CODE" "NV_VMF_INSERT_PFN_PROT_PRESENT" "" "functions"
        ;;

        drm_atomic_available)
            #
            # Determine if the DRM atomic modesetting subsystem is usable
            #
            # Added by commit 036ef5733ba4
            # ("drm/atomic: Allow drivers to subclass drm_atomic_state, v3") in
            # v4.2 (2018-05-18).
            #
            # Make conftest more robust by adding test for
            # drm_atomic_set_mode_prop_for_crtc(), this function added by
            # commit 955f3c334f0f ("drm/atomic: Add MODE_ID property") in v4.2
            # (2015-05-25). If the DRM atomic modesetting subsystem is
            # back ported to Linux kernel older than v4.2, then commit
            # 955f3c334f0f must be back ported in order to get NVIDIA-DRM KMS
            # support.
            # Commit 72fdb40c1a4b ("drm: extract drm_atomic_uapi.c") in v4.20
            # (2018-09-05), moved drm_atomic_set_mode_prop_for_crtc() function
            # prototype from drm/drm_atomic.h to drm/drm_atomic_uapi.h.
            #
            echo "$CONFTEST_PREAMBLE
            #if defined(NV_DRM_DRMP_H_PRESENT)
            #include <drm/drmP.h>
            #endif
            #include <drm/drm_atomic.h>
            #if !defined(CONFIG_DRM) && !defined(CONFIG_DRM_MODULE)
            #error DRM not enabled
            #endif
            void conftest_drm_atomic_modeset_available(void) {
                size_t a;

                a = offsetof(struct drm_mode_config_funcs, atomic_state_alloc);
            }" > conftest$$.c;

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                rm -f conftest$$.o

                echo "$CONFTEST_PREAMBLE
                #if defined(NV_DRM_DRMP_H_PRESENT)
                #include <drm/drmP.h>
                #endif
                #include <drm/drm_atomic.h>
                #if defined(NV_DRM_DRM_ATOMIC_UAPI_H_PRESENT)
                #include <drm/drm_atomic_uapi.h>
                #endif
                void conftest_drm_atomic_set_mode_prop_for_crtc(void) {
                    drm_atomic_set_mode_prop_for_crtc();
                }" > conftest$$.c;

                $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
                rm -f conftest$$.c

                if [ -f conftest$$.o ]; then
                    rm -f conftest$$.o
                    echo "#undef NV_DRM_ATOMIC_MODESET_AVAILABLE" | append_conftest "generic"
                else
                    echo "#define NV_DRM_ATOMIC_MODESET_AVAILABLE" | append_conftest "generic"
                fi
            else
                echo "#undef NV_DRM_ATOMIC_MODESET_AVAILABLE" | append_conftest "generic"
            fi
        ;;

        drm_bus_present)
            #
            # Determine if the 'struct drm_bus' type is present.
            #
            # Added by commit 8410ea3b95d1 ("drm: rework PCI/platform driver
            # interface.") in v2.6.39 (2010-12-15)
            #
            # Removed by commit c5786fe5f1c5 ("drm: Goody bye, drm_bus!")
            # in v3.18 (2014-08-29)
            #
            CODE="
            #if defined(NV_DRM_DRMP_H_PRESENT)
            #include <drm/drmP.h>
            #endif

            void conftest_drm_bus_present(void) {
                struct drm_bus bus;
            }"

            compile_check_conftest "$CODE" "NV_DRM_BUS_PRESENT" "" "types"
        ;;

        drm_bus_has_bus_type)
            #
            # Determine if the 'drm_bus' structure has a 'bus_type' field.
            #
            # Added by commit 8410ea3b95d1 ("drm: rework PCI/platform driver
            # interface.") in v2.6.39 (2010-12-15)
            #
            # Removed by commit 42b21049fc26 ("drm: kill drm_bus->bus_type")
            # in v3.16 (2013-11-03)
            #
            CODE="
            #if defined(NV_DRM_DRMP_H_PRESENT)
            #include <drm/drmP.h>
            #endif

            int conftest_drm_bus_has_bus_type(void) {
                return offsetof(struct drm_bus, bus_type);
            }"

            compile_check_conftest "$CODE" "NV_DRM_BUS_HAS_BUS_TYPE" "" "types"
        ;;

        drm_bus_has_get_irq)
            #
            # Determine if the 'drm_bus' structure has a 'get_irq' field.
            #
            # Added by commit 8410ea3b95d1 ("drm: rework PCI/platform
            # driver interface.") in v2.6.39 (2010-12-15)
            #
            # Removed by commit b2a21aa25a39 ("drm: remove bus->get_irq
            # implementations") in v3.16 (2013-11-03)
            #
            CODE="
            #if defined(NV_DRM_DRMP_H_PRESENT)
            #include <drm/drmP.h>
            #endif

            int conftest_drm_bus_has_get_irq(void) {
                return offsetof(struct drm_bus, get_irq);
            }"

            compile_check_conftest "$CODE" "NV_DRM_BUS_HAS_GET_IRQ" "" "types"
        ;;

        drm_bus_has_get_name)
            #
            # Determine if the 'drm_bus' structure has a 'get_name' field.
            #
            # Added by commit 8410ea3b95d1 ("drm: rework PCI/platform driver
            # interface.") in v2.6.39 (2010-12-15)
            #
            # removed by commit 9de1b51f1fae ("drm: remove drm_bus->get_name")
            # in v3.16 (2013-11-03)
            #
            CODE="
            #if defined(NV_DRM_DRMP_H_PRESENT)
            #include <drm/drmP.h>
            #endif

            int conftest_drm_bus_has_get_name(void) {
                return offsetof(struct drm_bus, get_name);
            }"

            compile_check_conftest "$CODE" "NV_DRM_BUS_HAS_GET_NAME" "" "types"
        ;;

        drm_driver_has_device_list)
            #
            # Determine if the 'drm_driver' structure has a 'device_list' field.
            #
            # Renamed from device_list to legacy_device_list by commit
            # b3f2333de8e8 ("drm: restrict the device list for shadow
            # attached drivers") in v3.14 (2013-12-11)
            #
            CODE="
            #if defined(NV_DRM_DRMP_H_PRESENT)
            #include <drm/drmP.h>
            #endif

            #if defined(NV_DRM_DRM_DRV_H_PRESENT)
            #include <drm/drm_drv.h>
            #endif

            int conftest_drm_driver_has_device_list(void) {
                return offsetof(struct drm_driver, device_list);
            }"

            compile_check_conftest "$CODE" "NV_DRM_DRIVER_HAS_DEVICE_LIST" "" "types"
        ;;


        drm_driver_has_legacy_dev_list)
            #
            # Determine if the 'drm_driver' structure has a 'legacy_dev_list' field.
            #
            # Renamed from device_list to legacy_device_list by commit
            # b3f2333de8e8 ("drm: restrict the device list for shadow
            # attached drivers") in v3.14 (2013-12-11)
            #
            # The commit 57bb1ee60340 ("drm: Compile out legacy chunks from
            # struct drm_device") compiles out the legacy chunks like
            # drm_driver::legacy_dev_list.
            #
            CODE="
            #if defined(NV_DRM_DRMP_H_PRESENT)
            #include <drm/drmP.h>
            #endif

            #if defined(NV_DRM_DRM_DRV_H_PRESENT)
            #include <drm/drm_drv.h>
            #endif

            int conftest_drm_driver_has_legacy_dev_list(void) {
                return offsetof(struct drm_driver, legacy_dev_list);
            }"

            compile_check_conftest "$CODE" "NV_DRM_DRIVER_HAS_LEGACY_DEV_LIST" "" "types"
        ;;

        jiffies_to_timespec)
            #
            # Determine if jiffies_to_timespec() is present
            #
            # removed by commit 751addac78b6
            # ("y2038: remove obsolete jiffies conversion functions")
            # in v5.6-rc1 (2019-12-13).
        CODE="
        #include <linux/jiffies.h>
        void conftest_jiffies_to_timespec(void){
            jiffies_to_timespec();
        }"
            compile_check_conftest "$CODE" "NV_JIFFIES_TO_TIMESPEC_PRESENT" "" "functions"
        ;;

        drm_init_function_args)
            #
            # Determine if these functions:
            #   drm_universal_plane_init()
            #   drm_crtc_init_with_planes()
            #   drm_encoder_init()
            # have a 'name' argument, which was added by these commits:
            #   drm_universal_plane_init:   2015-12-09  b0b3b7951114315d65398c27648705ca1c322faa
            #   drm_crtc_init_with_planes:  2015-12-09  f98828769c8838f526703ef180b3088a714af2f9
            #   drm_encoder_init:           2015-12-09  13a3d91f17a5f7ed2acd275d18b6acfdb131fb15
            #
            # Additionally determine whether drm_universal_plane_init() has a
            # 'format_modifiers' argument, which was added by:
            #   2017-07-23  e6fc3b68558e4c6d8d160b5daf2511b99afa8814
            #
            CODE="
            #if defined(NV_DRM_DRMP_H_PRESENT)
            #include <drm/drmP.h>
            #endif

            #if defined(NV_DRM_DRM_CRTC_H_PRESENT)
            #include <drm/drm_crtc.h>
            #endif

            int conftest_drm_crtc_init_with_planes_has_name_arg(void) {
                return
                    drm_crtc_init_with_planes(
                            NULL,  /* struct drm_device *dev */
                            NULL,  /* struct drm_crtc *crtc */
                            NULL,  /* struct drm_plane *primary */
                            NULL,  /* struct drm_plane *cursor */
                            NULL,  /* const struct drm_crtc_funcs *funcs */
                            NULL);  /* const char *name */
            }"

            compile_check_conftest "$CODE" "NV_DRM_CRTC_INIT_WITH_PLANES_HAS_NAME_ARG" "" "types"

            CODE="
            #if defined(NV_DRM_DRMP_H_PRESENT)
            #include <drm/drmP.h>
            #endif

            #if defined(NV_DRM_DRM_ENCODER_H_PRESENT)
            #include <drm/drm_encoder.h>
            #endif

            int conftest_drm_encoder_init_has_name_arg(void) {
                return
                    drm_encoder_init(
                            NULL,  /* struct drm_device *dev */
                            NULL,  /* struct drm_encoder *encoder */
                            NULL,  /* const struct drm_encoder_funcs *funcs */
                            DRM_MODE_ENCODER_NONE, /* int encoder_type */
                            NULL); /* const char *name */
            }"

            compile_check_conftest "$CODE" "NV_DRM_ENCODER_INIT_HAS_NAME_ARG" "" "types"

            echo "$CONFTEST_PREAMBLE
            #if defined(NV_DRM_DRMP_H_PRESENT)
            #include <drm/drmP.h>
            #endif

            #if defined(NV_DRM_DRM_PLANE_H_PRESENT)
            #include <drm/drm_plane.h>
            #endif

            int conftest_drm_universal_plane_init_has_format_modifiers_arg(void) {
                return
                    drm_universal_plane_init(
                            NULL,  /* struct drm_device *dev */
                            NULL,  /* struct drm_plane *plane */
                            0,     /* unsigned long possible_crtcs */
                            NULL,  /* const struct drm_plane_funcs *funcs */
                            NULL,  /* const uint32_t *formats */
                            0,     /* unsigned int format_count */
                            NULL,  /* const uint64_t *format_modifiers */
                            DRM_PLANE_TYPE_PRIMARY,
                            NULL);  /* const char *name */
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                rm -f conftest$$.o

                echo "#define NV_DRM_UNIVERSAL_PLANE_INIT_HAS_FORMAT_MODIFIERS_ARG" | append_conftest "types"
                echo "#define NV_DRM_UNIVERSAL_PLANE_INIT_HAS_NAME_ARG" | append_conftest "types"
            else
                echo "#undef NV_DRM_UNIVERSAL_PLANE_INIT_HAS_FORMAT_MODIFIERS_ARG" | append_conftest "types"

                CODE="
                #if defined(NV_DRM_DRMP_H_PRESENT)
                #include <drm/drmP.h>
                #endif

                #if defined(NV_DRM_DRM_PLANE_H_PRESENT)
                #include <drm/drm_plane.h>
                #endif

                int conftest_drm_universal_plane_init_has_name_arg(void) {
                    return
                        drm_universal_plane_init(
                                NULL,  /* struct drm_device *dev */
                                NULL,  /* struct drm_plane *plane */
                                0,     /* unsigned long possible_crtcs */
                                NULL,  /* const struct drm_plane_funcs *funcs */
                                NULL,  /* const uint32_t *formats */
                                0,     /* unsigned int format_count */
                                DRM_PLANE_TYPE_PRIMARY,
                                NULL);  /* const char *name */
                }"

                compile_check_conftest "$CODE" "NV_DRM_UNIVERSAL_PLANE_INIT_HAS_NAME_ARG" "" "types"
            fi
        ;;

        drm_driver_has_set_busid)
            #
            # Determine if the drm_driver structure has a 'set_busid' callback
            # field.
            #
            # Added by commit 915b4d11b8b9 ("drm: add driver->set_busid()
            # callback") in v3.18 (2014-08-29)
            #
            CODE="
            #if defined(NV_DRM_DRMP_H_PRESENT)
            #include <drm/drmP.h>
            #endif

            int conftest_drm_driver_has_set_busid(void) {
                return offsetof(struct drm_driver, set_busid);
            }"

            compile_check_conftest "$CODE" "NV_DRM_DRIVER_HAS_SET_BUSID" "" "types"
        ;;

        drm_driver_has_gem_prime_res_obj)
            #
            # Determine if the drm_driver structure has a 'gem_prime_res_obj'
            # callback field.
            #
            # Added by commit 3aac4502fd3f ("dma-buf: use reservation
            # objects") in v3.17 (2014-07-01).
            #
            # Removed by commit 51c98747113e (drm/prime: Ditch
            # gem_prime_res_obj hook) in v5.4.
            #
            CODE="
            #if defined(NV_DRM_DRMP_H_PRESENT)
            #include <drm/drmP.h>
            #endif

            int conftest_drm_driver_has_gem_prime_res_obj(void) {
                return offsetof(struct drm_driver, gem_prime_res_obj);
            }"

            compile_check_conftest "$CODE" "NV_DRM_DRIVER_HAS_GEM_PRIME_RES_OBJ" "" "types"
        ;;

        drm_crtc_state_has_connectors_changed)
            #
            # Determine if the crtc_state has a 'connectors_changed' field.
            #
            # Added by commit fc596660dd4e ("drm/atomic: add
            # connectors_changed to separate it from mode_changed, v2")
            # in v4.3 (2015-07-21)
            #
            CODE="
            #include <drm/drm_crtc.h>
            void conftest_drm_crtc_state_has_connectors_changed(void) {
                struct drm_crtc_state foo;
                (void)foo.connectors_changed;
            }"

            compile_check_conftest "$CODE" "NV_DRM_CRTC_STATE_HAS_CONNECTORS_CHANGED" "" "types"
        ;;

        drm_reinit_primary_mode_group)
            #
            # Determine if the function drm_reinit_primary_mode_group() is
            # present.
            #
            # Added by commit 2390cd11bfbe ("drm/crtc: add interface to
            # reinitialise the legacy mode group") in v3.17 (2014-06-05)
            #
            # Removed by commit 3fdefa399e46 ("drm: gc now dead
            # mode_group code") in v4.3 (2015-07-09)
            #
            CODE="
            #if defined(NV_DRM_DRM_CRTC_H_PRESENT)
            #include <drm/drm_crtc.h>
            #endif
            void conftest_drm_reinit_primary_mode_group(void) {
                drm_reinit_primary_mode_group();
            }"

            compile_check_conftest "$CODE" "NV_DRM_REINIT_PRIMARY_MODE_GROUP_PRESENT" "" "functions"
        ;;

        drm_helper_crtc_enable_color_mgmt)
            #
            # Determine if the function drm_helper_crtc_enable_color_mgmt() is
            # present.
            #
            # Added by commit 5488dc16fde7 ("drm: introduce pipe color
            # correction properties") in v4.6 (2016-03-08).
            #
            # Removed by commit f8ed34ac7b45 ("drm: drm_helper_crtc_enable_color_mgmt()
            # => drm_crtc_enable_color_mgmt()") in v4.8-rc1 (2016-06-07).
            #
            CODE="
            #include <drm/drm_crtc_helper.h>
            void conftest_drm_helper_crtc_enable_color_mgmt(void) {
                drm_helper_crtc_enable_color_mgmt();
            }"

            compile_check_conftest "$CODE" "NV_DRM_HELPER_CRTC_ENABLE_COLOR_MGMT_PRESENT" "" "functions"

        ;;

        drm_crtc_enable_color_mgmt)
            #
            # Determine if the function drm_crtc_enable_color_mgmt() is
            # present.
            #
            # Added by commit f8ed34ac7b45 ("drm: drm_helper_crtc_enable_color_mgmt()
            # => drm_crtc_enable_color_mgmt()") in v4.8-rc1 (2016-06-07), replacing
            # drm_helper_crtc_enable_color_mgmt().
            #
            # Moved to drm_color_mgmt.[ch] by commit f1e2f66ce2d9 ("drm: Extract
            # drm_color_mgmt.[hc]") in v4.9-rc1 (2016-09-22)
            #
            CODE="
            #if defined(NV_DRM_DRM_CRTC_H_PRESENT)
            #include <drm/drm_crtc.h>
            #endif
            #if defined(NV_DRM_DRM_COLOR_MGMT_H_PRESENT)
            #include <drm/drm_color_mgmt.h>
            #endif
            void conftest_drm_crtc_enable_color_mgmt(void) {
                drm_crtc_enable_color_mgmt();
            }"

            compile_check_conftest "$CODE" "NV_DRM_CRTC_ENABLE_COLOR_MGMT_PRESENT" "" "functions"
        ;;

        drm_atomic_helper_legacy_gamma_set)
            #
            # Determine if the function drm_atomic_helper_legacy_gamma_set() is
            # present.
            #
            # Added by commit 5488dc16fde7 ("drm: introduce pipe color
            # correction properties") in v4.6 (2016-03-08)
            #
            # Accidentally moved to drm_atomic_state_helper.[ch] by commit
            # 9ef8a9dc4b21 ("drm: Extract drm_atomic_state_helper.[ch]")
            # and moved back to drm_atomic_helper.[ch] by commit 1d8224e790c7
            # ("drm: Fix up drm_atomic_state_helper.[hc] extraction") in
            # v5.0-rc1
            #
            # Removed by commit 6ca2ab8086af ("drm: automatic legacy gamma
            # support") in v5.12 (2020-12-15)
            #
            CODE="
            #if defined(NV_DRM_DRM_ATOMIC_HELPER_H_PRESENT)
            #include <drm/drm_atomic_helper.h>
            #endif
            #if defined(NV_DRM_DRM_ATOMIC_STATE_HELPER_H_PRESENT)
            #include <drm/drm_atomic_state_helper.h>
            #endif
            void conftest_drm_atomic_helper_legacy_gamma_set(void) {
                drm_atomic_helper_legacy_gamma_set();
            }"

            compile_check_conftest "$CODE" "NV_DRM_ATOMIC_HELPER_LEGACY_GAMMA_SET_PRESENT" "" "functions"
        ;;

        wait_on_bit_lock_argument_count)
            #
            # Determine how many arguments wait_on_bit_lock takes.
            #
            # Changed by commit 743162013d40 ("sched: Remove proliferation
            # of wait_on_bit() action functions") in v3.17 (2014-07-07)
            #
            echo "$CONFTEST_PREAMBLE
            #include <linux/wait.h>
            void conftest_wait_on_bit_lock(void) {
                wait_on_bit_lock(NULL, 0, 0);
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                rm -f conftest$$.o
                echo "#define NV_WAIT_ON_BIT_LOCK_ARGUMENT_COUNT 3" | append_conftest "functions"
                return
            fi

            echo "$CONFTEST_PREAMBLE
            #include <linux/wait.h>
            void conftest_wait_on_bit_lock(void) {
                wait_on_bit_lock(NULL, 0, NULL, 0);
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                rm -f conftest$$.o
                echo "#define NV_WAIT_ON_BIT_LOCK_ARGUMENT_COUNT 4" | append_conftest "functions"
                return
            fi
            echo "#error wait_on_bit_lock() conftest failed!" | append_conftest "functions"
        ;;

        pci_stop_and_remove_bus_device)
            #
            # Determine if the pci_stop_and_remove_bus_device() function is present.
            #
            # Added by commit 210647af897a ("PCI: Rename pci_remove_bus_device
            # to pci_stop_and_remove_bus_device") in v3.4 (2012-02-25) but
            # aarch64 support was added by commit d1e6dc91b532 
            # ("arm64: Add architectural support for PCI") in v3.18-rc1.
            #
            CODE="
            #include <linux/types.h>
            #include <linux/pci.h>
            void conftest_pci_stop_and_remove_bus_device() {
                pci_stop_and_remove_bus_device();
            }"

            compile_check_conftest "$CODE" "NV_PCI_STOP_AND_REMOVE_BUS_DEVICE_PRESENT" "" "functions"
        ;;

        drm_helper_mode_fill_fb_struct | drm_helper_mode_fill_fb_struct_has_const_mode_cmd_arg)
            #
            # Determine if the drm_helper_mode_fill_fb_struct function takes
            # 'dev' argument.
            #
            # The drm_helper_mode_fill_fb_struct() has been updated to
            # take 'dev' parameter by commit a3f913ca9892 ("drm: Pass 'dev'
            # to drm_helper_mode_fill_fb_struct()") in v4.11 (2016-12-14)
            #
            echo "$CONFTEST_PREAMBLE
            #include <drm/drm_crtc_helper.h>
            void drm_helper_mode_fill_fb_struct(struct drm_device *dev,
                                                struct drm_framebuffer *fb,
                                                const struct drm_mode_fb_cmd2 *mode_cmd)
            {
                return;
            }" > conftest$$.c;

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                echo "#define NV_DRM_HELPER_MODE_FILL_FB_STRUCT_HAS_DEV_ARG" | append_conftest "function"
                echo "#define NV_DRM_HELPER_MODE_FILL_FB_STRUCT_HAS_CONST_MODE_CMD_ARG" | append_conftest "function"
                rm -f conftest$$.o
            else
                echo "#undef NV_DRM_HELPER_MODE_FILL_FB_STRUCT_HAS_DEV_ARG" | append_conftest "function"

                #
                # Determine if the drm_mode_fb_cmd2 pointer argument is const in
                # drm_mode_config_funcs::fb_create and drm_helper_mode_fill_fb_struct().
                #
                # The drm_mode_fb_cmd2 pointer through this call chain was made
                # const by commit 1eb83451ba55 ("drm: Pass the user drm_mode_fb_cmd2
                # as const to .fb_create()") in v4.5 (2015-11-11)
                #
                echo "$CONFTEST_PREAMBLE
                #include <drm/drm_crtc_helper.h>
                void drm_helper_mode_fill_fb_struct(struct drm_framebuffer *fb,
                                                    const struct drm_mode_fb_cmd2 *mode_cmd)
                {
                    return;
                }" > conftest$$.c;

                $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
                rm -f conftest$$.c

                if [ -f conftest$$.o ]; then
                    echo "#define NV_DRM_HELPER_MODE_FILL_FB_STRUCT_HAS_CONST_MODE_CMD_ARG" | append_conftest "function"
                    rm -f conftest$$.o
                else
                    echo "#undef NV_DRM_HELPER_MODE_FILL_FB_STRUCT_HAS_CONST_MODE_CMD_ARG" | append_conftest "function"
                fi
            fi
        ;;

        mm_context_t)
            #
            # Determine if the 'mm_context_t' data type is present
            # and if it has an 'id' member.
            # It does not exist on all architectures.
            #
            echo "$CONFTEST_PREAMBLE
            #include <linux/mm.h>
            int conftest_mm_context_t(void) {
                return offsetof(mm_context_t, id);
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                echo "#define NV_MM_CONTEXT_T_HAS_ID" | append_conftest "types"
                rm -f conftest$$.o
                return
            else
                echo "#undef NV_MM_CONTEXT_T_HAS_ID" | append_conftest "types"
                return
            fi
        ;;

        pci_dev_has_ats_enabled)
            #
            # Determine if the 'pci_dev' data type has a 'ats_enabled' member.
            #
            # Added by commit d544d75ac96aa ("PCI: Embed ATS info directly
            # into struct pci_dev") in v4.3-rc1 (2015-08-14)
            #
            CODE="
            #include <linux/pci.h>
            int conftest_pci_dev_ats_enabled_t(void) {
                return ((struct pci_dev *)0)->ats_enabled;
            }"

            compile_check_conftest "$CODE" "NV_PCI_DEV_HAS_ATS_ENABLED" "" "types"
        ;;

        get_file_rcu_has_double_ptr_file_arg)
            #
            # Determine if the function 'get_file_rcu()' has pointer to pointer of file
            # type argument or not.
            #
            # In Linux v6.7, commit 0ede61d8589cc2 ("file: convert to SLAB_TYPESAFE_BY_RCU")
            # changed the argument of file handle to pointer type.
            #
            CODE="
            #include <linux/fs.h>
            struct file *conftest_get_file_rcu_has_double_ptr_file_arg(struct file __rcu *f) {
                    return get_file_rcu(&f);
            }"

            compile_check_conftest "$CODE" "NV_GET_FILE_RCU_HAS_DOUBLE_PTR_FILE_ARG" "" "types"
        ;;

        get_user_pages)
            #
            # Conftest for get_user_pages()
            #
            # Use long type for get_user_pages and unsigned long for nr_pages
            # by commit 28a35716d317 ("mm: use long type for page counts
            # in mm_populate() and get_user_pages()") in v3.9 (2013-02-22)
            #
            # Removed struct task_struct *tsk & struct mm_struct *mm from
            # get_user_pages by commit cde70140fed8 ("mm/gup: Overload
            # get_user_pages() functions") in v4.6 (2016-02-12)
            #
            # Replaced get_user_pages6 with get_user_pages by commit
            # c12d2da56d0e ("mm/gup: Remove the macro overload API migration
            # helpers from the get_user*() APIs") in v4.6 (2016-04-04)
            #
            # Replaced write and force parameters with gup_flags by
            # commit 768ae309a961 ("mm: replace get_user_pages() write/force
            # parameters with gup_flags") in v4.9 (2016-10-13)
            #
            # Removed vmas parameter from get_user_pages() by commit 54d020692b34
            # ("mm/gup: remove unused vmas parameter from get_user_pages()")
            # in v6.5.
            #
            # linux-4.4.168 cherry-picked commit 768ae309a961 without
            # c12d2da56d0e which is covered in Conftest #3.
            #

            #
            # This function sets the NV_GET_USER_PAGES_* macros as per the below
            # passing conftest's
            #
            set_get_user_pages_defines () {
                if [ "$1" = "NV_GET_USER_PAGES_HAS_ARGS_WRITE_FORCE_VMAS" ]; then
                    echo "#define NV_GET_USER_PAGES_HAS_ARGS_WRITE_FORCE_VMAS" | append_conftest "functions"
                else
                    echo "#undef NV_GET_USER_PAGES_HAS_ARGS_WRITE_FORCE_VMAS" | append_conftest "functions"
                fi

                if [ "$1" = "NV_GET_USER_PAGES_HAS_ARGS_TSK_WRITE_FORCE_VMAS" ]; then
                    echo "#define NV_GET_USER_PAGES_HAS_ARGS_TSK_WRITE_FORCE_VMAS" | append_conftest "functions"
                else
                    echo "#undef NV_GET_USER_PAGES_HAS_ARGS_TSK_WRITE_FORCE_VMAS" | append_conftest "functions"
                fi

                if [ "$1" = "NV_GET_USER_PAGES_HAS_ARGS_TSK_FLAGS_VMAS" ]; then
                    echo "#define NV_GET_USER_PAGES_HAS_ARGS_TSK_FLAGS_VMAS" | append_conftest "functions"
                else
                    echo "#undef NV_GET_USER_PAGES_HAS_ARGS_TSK_FLAGS_VMAS" | append_conftest "functions"
                fi

                if [ "$1" = "NV_GET_USER_PAGES_HAS_ARGS_FLAGS_VMAS" ]; then
                    echo "#define NV_GET_USER_PAGES_HAS_ARGS_FLAGS_VMAS" | append_conftest "functions"
                else
                    echo "#undef NV_GET_USER_PAGES_HAS_ARGS_FLAGS_VMAS" | append_conftest "functions"
                fi

                if [ "$1" = "NV_GET_USER_PAGES_HAS_ARGS_FLAGS" ]; then
                    echo "#define NV_GET_USER_PAGES_HAS_ARGS_FLAGS" | append_conftest "functions"
                else
                    echo "#undef NV_GET_USER_PAGES_HAS_ARGS_FLAGS" | append_conftest "functions"
                fi

            }

            # Conftest #1: Check if get_user_pages accepts 6 arguments.
            # Return if true.
            # Fall through to conftest #2 on failure.

            echo "$CONFTEST_PREAMBLE
            #include <linux/mm.h>
            long get_user_pages(unsigned long start,
                                unsigned long nr_pages,
                                int write,
                                int force,
                                struct page **pages,
                                struct vm_area_struct **vmas) {
                return 0;
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c
            if [ -f conftest$$.o ]; then
                set_get_user_pages_defines "NV_GET_USER_PAGES_HAS_ARGS_WRITE_FORCE_VMAS"
                rm -f conftest$$.o
                return
            fi

            # Conftest #2: Check if get_user_pages has gup_flags instead of
            # write and force parameters. And that gup doesn't accept a
            # task_struct and mm_struct as its first arguments. get_user_pages
            # has vm_area_struct as its last argument.
            # Return if available.
            # Fall through to conftest #3 on failure.

            echo "$CONFTEST_PREAMBLE
            #include <linux/mm.h>
            long get_user_pages(unsigned long start,
                                unsigned long nr_pages,
                                unsigned int gup_flags,
                                struct page **pages,
                                struct vm_area_struct **vmas) {
                return 0;
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                set_get_user_pages_defines "NV_GET_USER_PAGES_HAS_ARGS_FLAGS_VMAS"
                rm -f conftest$$.o
                return
            fi

            # Conftest #3: Check if get_user_pages has gup_flags instead of
            # write and force parameters. The gup has task_struct and
            # mm_struct as its first arguments. get_user_pages
            # has vm_area_struct as its last argument.
            # Return if available.
            # Fall through to conftest #4 on failure.

            echo "$CONFTEST_PREAMBLE
            #include <linux/mm.h>
            long get_user_pages(struct task_struct *tsk,
                                struct mm_struct *mm,
                                unsigned long start,
                                unsigned long nr_pages,
                                unsigned int gup_flags,
                                struct page **pages,
                                struct vm_area_struct **vmas) {
                return 0;
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                set_get_user_pages_defines "NV_GET_USER_PAGES_HAS_ARGS_TSK_FLAGS_VMAS"
                rm -f conftest$$.o
                return
            fi

            # Conftest #4: gup doesn't accept a task_struct and mm_struct as
            # its first arguments. check if get_user_pages() does not take
            # vmas argument.
            # Fall through to default case otherwise.

            echo "$CONFTEST_PREAMBLE
            #include <linux/mm.h>
            long get_user_pages(unsigned long start,
                                unsigned long nr_pages,
                                unsigned int gup_flags,
                                struct page **pages) {
                return 0;
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                set_get_user_pages_defines "NV_GET_USER_PAGES_HAS_ARGS_FLAGS"
                rm -f conftest$$.o
                return
            fi

            set_get_user_pages_defines "NV_GET_USER_PAGES_HAS_ARGS_TSK_WRITE_FORCE_VMAS"

            return
        ;;

        get_user_pages_remote)
            #
            # Determine if the function get_user_pages_remote() is
            # present and has write/force/locked/tsk parameters.
            #
            # get_user_pages_remote() was added by commit 1e9877902dc7
            # ("mm/gup: Introduce get_user_pages_remote()") in v4.6 (2016-02-12)
            #
            # get_user_pages[_remote]() write/force parameters
            # replaced with gup_flags by commits 768ae309a961 ("mm: replace
            # get_user_pages() write/force parameters with gup_flags") and
            # commit 9beae1ea8930 ("mm: replace get_user_pages_remote()
            # write/force parameters with gup_flags") in v4.9 (2016-10-13)
            #
            # get_user_pages_remote() added 'locked' parameter by
            # commit 5b56d49fc31d ("mm: add locked parameter to
            # get_user_pages_remote()") in v4.10 (2016-12-14)
            #
            # get_user_pages_remote() removed 'tsk' parameter by
            # commit 64019a2e467a ("mm/gup: remove task_struct pointer for
            # all gup code") in v5.9-rc1 (2020-08-11).
            #

            #
            # This function sets the NV_GET_USER_PAGES_REMOTE_* macros as per
            # the below passing conftest's
            #
            set_get_user_pages_remote_defines () {
                if [ "$1" = "" ]; then
                    echo "#undef NV_GET_USER_PAGES_REMOTE_PRESENT" | append_conftest "functions"
                else
                    echo "#define NV_GET_USER_PAGES_REMOTE_PRESENT" | append_conftest "functions"
                fi

                if [ "$1" = "NV_GET_USER_PAGES_REMOTE_HAS_ARGS_TSK_WRITE_FORCE" ]; then
                    echo "#define NV_GET_USER_PAGES_REMOTE_HAS_ARGS_TSK_WRITE_FORCE" | append_conftest "functions"
                else
                    echo "#undef NV_GET_USER_PAGES_REMOTE_HAS_ARGS_TSK_WRITE_FORCE" | append_conftest "functions"
                fi

                if [ "$1" = "NV_GET_USER_PAGES_REMOTE_HAS_ARGS_TSK_FLAGS" ]; then
                    echo "#define NV_GET_USER_PAGES_REMOTE_HAS_ARGS_TSK_FLAGS" | append_conftest "functions"
                else
                    echo "#undef NV_GET_USER_PAGES_REMOTE_HAS_ARGS_TSK_FLAGS" | append_conftest "functions"
                fi

                if [ "$1" = "NV_GET_USER_PAGES_REMOTE_HAS_ARGS_TSK_FLAGS_LOCKED" ]; then
                    echo "#define NV_GET_USER_PAGES_REMOTE_HAS_ARGS_TSK_FLAGS_LOCKED" | append_conftest "functions"
                else
                    echo "#undef NV_GET_USER_PAGES_REMOTE_HAS_ARGS_TSK_FLAGS_LOCKED" | append_conftest "functions"
                fi

                if [ "$1" = "NV_GET_USER_PAGES_REMOTE_HAS_ARGS_FLAGS_LOCKED" ]; then
                    echo "#define NV_GET_USER_PAGES_REMOTE_HAS_ARGS_FLAGS_LOCKED" | append_conftest "functions"
                else
                    echo "#undef NV_GET_USER_PAGES_REMOTE_HAS_ARGS_FLAGS_LOCKED" | append_conftest "functions"
                fi
            }

            # conftest #1: check if get_user_pages_remote() is available
            # return if not available.
            # Fall through to conftest #2 if it is present

            echo "$CONFTEST_PREAMBLE
            #include <linux/mm.h>
            void conftest_get_user_pages_remote(void) {
                get_user_pages_remote();
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                set_get_user_pages_remote_defines ""
                rm -f conftest$$.o
                return
            fi

            #
            # conftest #2: check if get_user_pages_remote() has write and
            # force arguments. Return if these arguments are present
            # Fall through to conftest #3 if these args are absent.
            #
            echo "$CONFTEST_PREAMBLE
            #include <linux/mm.h>
            long get_user_pages_remote(struct task_struct *tsk,
                                       struct mm_struct *mm,
                                       unsigned long start,
                                       unsigned long nr_pages,
                                       int write,
                                       int force,
                                       struct page **pages,
                                       struct vm_area_struct **vmas) {
                return 0;
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                set_get_user_pages_remote_defines "NV_GET_USER_PAGES_REMOTE_HAS_ARGS_TSK_WRITE_FORCE"
                rm -f conftest$$.o
                return
            fi

            #
            # conftest #3: check if get_user_pages_remote() has gpu_flags
            # arguments. Return if these arguments are present
            # Fall through to conftest #4 if these args are absent.
            #
            echo "$CONFTEST_PREAMBLE
            #include <linux/mm.h>
            long get_user_pages_remote(struct task_struct *tsk,
                                       struct mm_struct *mm,
                                       unsigned long start,
                                       unsigned long nr_pages,
                                       unsigned int gpu_flags,
                                       struct page **pages,
                                       struct vm_area_struct **vmas) {
                return 0;
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                set_get_user_pages_remote_defines "NV_GET_USER_PAGES_REMOTE_HAS_ARGS_TSK_FLAGS"
                rm -f conftest$$.o
                return
            fi

            #
            # conftest #4: check if get_user_pages_remote() has locked argument
            # Return if these arguments are present. Fall through to conftest #5
            # if these args are absent.
            #
            echo "$CONFTEST_PREAMBLE
            #include <linux/mm.h>
            long get_user_pages_remote(struct task_struct *tsk,
                                       struct mm_struct *mm,
                                       unsigned long start,
                                       unsigned long nr_pages,
                                       unsigned int gup_flags,
                                       struct page **pages,
                                       struct vm_area_struct **vmas,
                                       int *locked) {
                return 0;
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                set_get_user_pages_remote_defines "NV_GET_USER_PAGES_REMOTE_HAS_ARGS_TSK_FLAGS_LOCKED"
                rm -f conftest$$.o
                return
            fi

            #
            # conftest #5: check if get_user_pages_remote() does not take
            # tsk argument.
            #
            echo "$CONFTEST_PREAMBLE
            #include <linux/mm.h>
            long get_user_pages_remote(struct mm_struct *mm,
                                       unsigned long start,
                                       unsigned long nr_pages,
                                       unsigned int gup_flags,
                                       struct page **pages,
                                       struct vm_area_struct **vmas,
                                       int *locked) {
                return 0;
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                set_get_user_pages_remote_defines "NV_GET_USER_PAGES_REMOTE_HAS_ARGS_FLAGS_LOCKED"
                rm -f conftest$$.o
            fi
        ;;

        pin_user_pages)
            #
            # Determine if the function pin_user_pages() is present.
            # Presence of pin_user_pages() also implies the presence of
            # unpin-user_page(). Both were added in the v5.6-rc1
            #
            # pin_user_pages() was added by commit eddb1c228f7951d399240
            # ("mm/gup: introduce pin_user_pages*() and FOLL_PIN") in
            # v5.6-rc1 (2020-01-30)

            # conftest #1: check if pin_user_pages() is available
            # return if not available.
            #
            CODE="
            #include <linux/mm.h>
            void conftest_pin_user_pages(void) {
                pin_user_pages();
            }"

            compile_check_conftest "$CODE" "NV_PIN_USER_PAGES_PRESENT" "" "functions"
        ;;

        pin_user_pages_remote)
            # Determine if the function pin_user_pages_remote() is present
            #
            # pin_user_pages_remote() was added by commit eddb1c228f7951d399240
            # ("mm/gup: introduce pin_user_pages*() and FOLL_PIN")
            # in v5.6 (2020-01-30)

            # pin_user_pages_remote() removed 'tsk' parameter by
            # commit 64019a2e467a ("mm/gup: remove task_struct pointer for
            # all gup code") in v5.9-rc1 (2020-08-11).

            #
            # This function sets the NV_PIN_USER_PAGES_REMOTE_* macros as per
            # the below passing conftest's
            #
            set_pin_user_pages_remote_defines () {
                if [ "$1" = "" ]; then
                    echo "#undef NV_PIN_USER_PAGES_REMOTE_PRESENT" | append_conftest "functions"
                else
                    echo "#define NV_PIN_USER_PAGES_REMOTE_PRESENT" | append_conftest "functions"
                fi

                if [ "$1" = "NV_PIN_USER_PAGES_REMOTE_HAS_ARGS_TSK" ]; then
                    echo "#define NV_PIN_USER_PAGES_REMOTE_HAS_ARGS_TSK" | append_conftest "functions"
                else
                    echo "#undef NV_PIN_USER_PAGES_REMOTE_HAS_ARGS_TSK" | append_conftest "functions"
                fi
            }

            # conftest #1: check if pin_user_pages_remote() is available
            # return if not available.
            # Fall through to conftest #2 if it is present
            #
            echo "$CONFTEST_PREAMBLE
            #include <linux/mm.h>
            void conftest_pin_user_pages_remote(void) {
                pin_user_pages_remote();
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                set_pin_user_pages_remote_defines ""
                rm -f conftest$$.o
                return
            fi

            # conftest #2: Check if pin_user_pages_remote() has tsk argument
            echo "$CONFTEST_PREAMBLE
            #include <linux/mm.h>
            long pin_user_pages_remote(struct task_struct *tsk,
                                       struct mm_struct *mm,
                                       unsigned long start,
                                       unsigned long nr_pages,
                                       unsigned int gup_flags,
                                       struct page **pages,
                                       struct vm_area_struct **vmas,
                                       int *locked) {
                return 0;
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                set_pin_user_pages_remote_defines "NV_PIN_USER_PAGES_REMOTE_HAS_ARGS_TSK"
                rm -f conftest$$.o
            else
                set_pin_user_pages_remote_defines "NV_PIN_USER_PAGES_REMOTE_PRESENT"
            fi
        ;;

        vfio_pin_pages_has_vfio_device_arg)
            #
            # Determine if vfio_pin_pages() kABI accepts "struct vfio_device *"
            # argument instead of "struct device *"
            #
            # Replaced "struct device *" with "struct vfio_device *" by commit
            # 8e432bb015b6c ("vfio/mdev: Pass in a struct vfio_device * to
            # vfio_pin/unpin_pages()") in v5.19
            #
            echo "$CONFTEST_PREAMBLE
            #include <linux/pci.h>
            #include <linux/vfio.h>
            int vfio_pin_pages(struct vfio_device *device,
                               unsigned long *user_pfn,
                               int npage,
                               int prot,
                               unsigned long *phys_pfn) {
                return 0;
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                echo "#define NV_VFIO_PIN_PAGES_HAS_VFIO_DEVICE_ARG" | append_conftest "functions"
                rm -f conftest$$.o
            else
                echo "#undef NV_VFIO_PIN_PAGES_HAS_VFIO_DEVICE_ARG" | append_conftest "functions"
            fi
        ;;

        vfio_pin_pages_has_pages_arg)
            #
            # Determine if vfio_pin_pages() kABI accepts "struct pages **:
            # argument instead of "unsigned long *phys_pfn"
            #
            # Replaced "unsigned long *phys_pfn" with "struct pages **pages"
            # in commit 34a255e676159 ("vfio: Replace phys_pfn with pages for
            # vfio_pin_pages()") in v6.0.
            #
            echo "$CONFTEST_PREAMBLE
            #include <linux/pci.h>
            #include <linux/vfio.h>
            int vfio_pin_pages(struct vfio_device *device,
                               dma_addr_t iova,
                               int npage,
                               int prot,
                               struct page **pages) {
                return 0;
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                echo "#define NV_VFIO_PIN_PAGES_HAS_PAGES_ARG" | append_conftest "functions"
                rm -f conftest$$.o
            else
                echo "#undef NV_VFIO_PIN_PAGES_HAS_PAGES_ARG" | append_conftest "functions"
            fi
        ;;

        enable_apicv)
            #
            # Determine if enable_apicv boolean is exported by kernel.
            #
            # Added by commit fdf513e37a3bd ("KVM: x86: Use common 'enable_apicv'
            # variable for both APICv and AVIC")
            #
            CODE="
            $CONFTEST_PREAMBLE
            #include <asm/kvm_host.h>

            bool is_enable_apicv_present() {
                return enable_apicv;
            }"

            compile_check_conftest "$CODE" "NV_ENABLE_APICV_PRESENT" "" "types"
        ;;

        pci_driver_has_driver_managed_dma)
            #
            # Determine if "struct pci_driver" has .driver_managed_dma member.
            #
            # Added by commit 512881eacfa7 ("bus: platform,amba,fsl-mc,PCI:
            # Add device DMA ownership management") in v5.19
            #
            CODE="
            #include <linux/pci.h>
            int conftest_pci_driver_has_driver_managed_dma(void) {
                return offsetof(struct pci_driver, driver_managed_dma);
            }"

            compile_check_conftest "$CODE" "NV_PCI_DRIVER_HAS_DRIVER_MANAGED_DMA" "" "types"
        ;;

        radix_tree_empty)
            #
            # Determine if the function radix_tree_empty() is present.
            #
            # Added by commit e9256efcc8e3 ("radix-tree: introduce
            # radix_tree_empty") in v4.7 (2016-05-20)
            #
            CODE="
            #include <linux/radix-tree.h>
            int conftest_radix_tree_empty(void) {
                radix_tree_empty();
            }"

            compile_check_conftest "$CODE" "NV_RADIX_TREE_EMPTY_PRESENT" "" "functions"
        ;;

        drm_gem_object_lookup)
            #
            # Determine the number of arguments of drm_gem_object_lookup().
            #
            # First argument of type drm_device removed by commit
            # a8ad0bd84f98 ("drm: Remove unused drm_device from
            # drm_gem_object_lookup()") in v4.7 (2016-05-09)
            #
            echo "$CONFTEST_PREAMBLE
            #if defined(NV_DRM_DRMP_H_PRESENT)
            #include <drm/drmP.h>
            #endif
            #if defined(NV_DRM_DRM_GEM_H_PRESENT)
            #include <drm/drm_gem.h>
            #endif
            void conftest_drm_gem_object_lookup(void) {
                drm_gem_object_lookup(NULL, NULL, 0);
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                echo "#define NV_DRM_GEM_OBJECT_LOOKUP_ARGUMENT_COUNT 3" | append_conftest "functions"
                rm -f conftest$$.o
                return
            else
                echo "#define NV_DRM_GEM_OBJECT_LOOKUP_ARGUMENT_COUNT 2" | append_conftest "functions"
            fi
        ;;

        drm_master_drop_has_from_release_arg)
            #
            # Determine if drm_driver::master_drop() has 'from_release' argument.
            #
            # Last argument 'bool from_release' has been removed by commit
            # d6ed682eba54 ("drm: Refactor drop/set master code a bit")
            # in v4.8 (2016-06-21)
            #
            CODE="
            #if defined(NV_DRM_DRMP_H_PRESENT)
            #include <drm/drmP.h>
            #endif

            void conftest_drm_master_drop_has_from_release_arg(struct drm_driver *drv) {
                drv->master_drop(NULL, NULL, false);
            }"

            compile_check_conftest "$CODE" "NV_DRM_MASTER_DROP_HAS_FROM_RELEASE_ARG" "" "types"
        ;;

        drm_master_has_leases)
            #
            # Determine if drm_master has 'leases', 'lessor', 'lessee_idr' fields.
            # Also checks for struct drm_mode_revoke_lease.
            #
            # Added by commits 2ed077e467ee ("drm: Add drm_object lease infrastructure [v5]")
            # and 62884cd386b8 ("drm: Add four ioctls for managing drm mode object leases [v7]")
            # in v4.15 (2017-10-24)
            #
            CODE="
            #if defined(NV_DRM_DRMP_H_PRESENT)
            #include <drm/drmP.h>
            #endif
            #if defined(NV_DRM_DRM_AUTH_H_PRESENT)
            #include <drm/drm_auth.h>
            #endif
            #include <uapi/drm/drm_mode.h>

            int conftest_drm_master_leases(void) {
                return offsetof(struct drm_master, leases);
            }
            int conftest_drm_master_lessor(void) {
                return offsetof(struct drm_master, lessor);
            }
            int conftest_drm_master_lessee_idr(void) {
                return offsetof(struct drm_master, lessee_idr);
            }
            int conftest_drm_mode_revoke_lease(void) {
                return offsetof(struct drm_mode_revoke_lease, lessee_id);
            }"

            compile_check_conftest "$CODE" "NV_DRM_MASTER_HAS_LEASES" "" "types"
        ;;

        drm_file_get_master)
            #
            # Determine if function drm_file_get_master() is present.
            #
            # Added by commit 56f0729a510f ("drm: protect drm_master pointers in drm_lease.c")
            # in v5.15 (2021-07-20)
            #

            CODE="
            #if defined(NV_DRM_DRMP_H_PRESENT)
            #include <drm/drmP.h>
            #endif
            #if defined(NV_DRM_DRM_AUTH_H_PRESENT)
            #include <drm/drm_auth.h>
            #endif

            void conftest_drm_file_get_master(void) {
                drm_file_get_master();
            }"

            compile_check_conftest "$CODE" "NV_DRM_FILE_GET_MASTER_PRESENT" "" "functions"
        ;;

        drm_connector_lookup)
            #
            # Determine if function drm_connector_lookup() is present.
            #
            # Added by commit b164d31f50b2 ("drm/modes: add connector reference
            # counting. (v2)") in v4.7 (2016-05-04), when it replaced
            # drm_connector_find(). 
            # 
            # It was originally added in drm_crtc.h, then moved to
            # drm_connector.h by commit 522171951761
            # ("drm: Extract drm_connector.[hc]") in v4.9 (2016-08-12)
            #

            CODE="
            #if defined(NV_DRM_DRM_CRTC_H_PRESENT)
            #include <drm/drm_crtc.h>
            #endif
            #if defined(NV_DRM_DRM_CONNECTOR_H_PRESENT)
            #include <drm/drm_connector.h>
            #endif
            void conftest_drm_connector_lookup(void) {
                drm_connector_lookup();
            }"

            compile_check_conftest "$CODE" "NV_DRM_CONNECTOR_LOOKUP_PRESENT" "" "functions"
        ;;

        drm_connector_put)
            #
            # Determine if function drm_connector_put() is present.
            #
            # Added by commit ad09360750af ("drm: Introduce 
            # drm_connector_{get,put}()") in v4.12 (2017-02-28),
            # when it replaced drm_connector_unreference() that
            # was added with NV_DRM_CONNECTOR_LOOKUP_PRESENT.
            #

            CODE="
            #if defined(NV_DRM_DRM_CONNECTOR_H_PRESENT)
            #include <drm/drm_connector.h>
            #endif
            void conftest_drm_connector_put(void) {
                drm_connector_put();
            }"

            compile_check_conftest "$CODE" "NV_DRM_CONNECTOR_PUT_PRESENT" "" "functions"
        ;;

        drm_modeset_lock_all_end)
            #
            # Determine the number of arguments of the
            # DRM_MODESET_LOCK_ALL_END() macro.
            #
            # DRM_MODESET_LOCK_ALL_END() is added with two arguments by commit
            # b7ea04d299c7 (drm: drm: Add DRM_MODESET_LOCK_BEGIN/END helpers)
            # in v5.0 (2018-11-29). The definition and prototype is changed to
            # also take the third argument drm_device, by commit 77ef38574beb
            # (drm/modeset-lock: Take the modeset BKL for legacy drivers)
            # in v5.9 (2020-08-17).
            #
            DRM_MODESET_3_COMPILED=0
            DRM_MODESET_2_COMPILED=0
            DRM_MODESET_INCLUDES="
                #if defined(NV_DRM_DRM_DEVICE_H_PRESENT)
                #include <drm/drm_device.h>
                #endif
                #if defined(NV_DRM_DRM_DRV_H_PRESENT)
                #include <drm/drm_drv.h>
                #endif
                #if defined(NV_DRM_DRM_MODESET_LOCK_H_PRESENT)
                #include <drm/drm_modeset_lock.h>
                #endif"

            echo "$CONFTEST_PREAMBLE
            $DRM_MODESET_INCLUDES

            void conftest_drm_modeset_lock_all_end(
                struct drm_device *dev,
                struct drm_modeset_acquire_ctx ctx,
                int ret) {
                DRM_MODESET_LOCK_ALL_BEGIN(dev, ctx, 0, ret);
                DRM_MODESET_LOCK_ALL_END(dev, ctx, ret);
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                DRM_MODESET_3_COMPILED=1
                rm -f conftest$$.o
            fi

            echo "$CONFTEST_PREAMBLE
            $DRM_MODESET_INCLUDES

            void conftest_drm_modeset_lock_all_end(
                struct drm_device *dev,
                struct drm_modeset_acquire_ctx ctx,
                int ret) {
                DRM_MODESET_LOCK_ALL_BEGIN(dev, ctx, 0, ret);
                DRM_MODESET_LOCK_ALL_END(ctx, ret);
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                DRM_MODESET_2_COMPILED=1
                rm -f conftest$$.o
            fi

            # If the macro is undefined, both code snippets will still compile,
            #  so we need to check both and make sure only one compiles successfully.
            if [ "$DRM_MODESET_3_COMPILED" = "1" ] &&
               [ "$DRM_MODESET_2_COMPILED" = "0" ]; then
                echo "#define NV_DRM_MODESET_LOCK_ALL_END_ARGUMENT_COUNT 3" | append_conftest "functions"
            elif [ "$DRM_MODESET_3_COMPILED" = "0" ] &&
                 [ "$DRM_MODESET_2_COMPILED" = "1" ]; then
                echo "#define NV_DRM_MODESET_LOCK_ALL_END_ARGUMENT_COUNT 2" | append_conftest "functions"
            else
                echo "#define NV_DRM_MODESET_LOCK_ALL_END_ARGUMENT_COUNT 0" | append_conftest "functions"
            fi
        ;;

        drm_atomic_state_ref_counting)
            #
            # Determine if functions drm_atomic_state_get/put() are
            # present.
            #
            # Added by commit 0853695c3ba4 ("drm: Add reference counting to
            # drm_atomic_state") in v4.10 (2016-10-14)
            #
            CODE="
            #if defined(NV_DRM_DRM_ATOMIC_H_PRESENT)
            #include <drm/drm_atomic.h>
            #endif
            void conftest_drm_atomic_state_get(void) {
                drm_atomic_state_get();
            }"

            compile_check_conftest "$CODE" "NV_DRM_ATOMIC_STATE_REF_COUNTING_PRESENT" "" "functions"
        ;;

        vm_ops_fault_removed_vma_arg)
            #
            # Determine if vma.vm_ops.fault takes (vma, vmf), or just (vmf)
            # args. Acronym key:
            #   vma: struct vm_area_struct
            #   vm_ops: struct vm_operations_struct
            #   vmf: struct vm_fault
            #
            # The redundant vma arg was removed from BOTH vma.vm_ops.fault and
            # vma.vm_ops.page_mkwrite by commit 11bac8000449 ("mm, fs: reduce
            # fault, page_mkwrite, and pfn_mkwrite to take only vmf") in
            # v4.11 (2017-02-24)
            #
            CODE="
            #include <linux/mm.h>
            void conftest_vm_ops_fault_removed_vma_arg(void) {
                struct vm_operations_struct vm_ops;
                struct vm_fault *vmf;
                (void)vm_ops.fault(vmf);
            }"

            compile_check_conftest "$CODE" "NV_VM_OPS_FAULT_REMOVED_VMA_ARG" "" "types"
        ;;

        pnv_npu2_init_context)
            #
            # Determine if the pnv_npu2_init_context() function is
            # present and the signature of its callback.
            #
            # Added by commit 1ab66d1fbada ("powerpc/powernv: Introduce
            # address translation services for Nvlink2") in v4.12
            # (2017-04-03).
            #
            echo "$CONFTEST_PREAMBLE
            #if defined(NV_ASM_POWERNV_H_PRESENT)
            #include <linux/pci.h>
            #include <asm/powernv.h>
            #endif
            void conftest_pnv_npu2_init_context(void) {
                pnv_npu2_init_context();
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c
            if [ -f conftest$$.o ]; then
                echo "#undef NV_PNV_NPU2_INIT_CONTEXT_PRESENT" | append_conftest "functions"
                echo "#undef NV_PNV_NPU2_INIT_CONTEXT_CALLBACK_RETURNS_VOID" | append_conftest "functions"
                rm -f conftest$$.o
                return
            fi

            echo "#define NV_PNV_NPU2_INIT_CONTEXT_PRESENT" | append_conftest "functions"

            # Check the callback signature
            echo "$CONFTEST_PREAMBLE
            #if defined(NV_ASM_POWERNV_H_PRESENT)
            #include <linux/pci.h>
            #include <asm/powernv.h>
            #endif

            struct npu_context *pnv_npu2_init_context(struct pci_dev *gpdev,
                unsigned long flags,
                void (*cb)(struct npu_context *, void *),
                void *priv) {
                return NULL;
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c
            if [ -f conftest$$.o ]; then
                echo "#define NV_PNV_NPU2_INIT_CONTEXT_CALLBACK_RETURNS_VOID" | append_conftest "functions"
                rm -f conftest$$.o
                return
            fi

            echo "#undef NV_PNV_NPU2_INIT_CONTEXT_CALLBACK_RETURNS_VOID" | append_conftest "functions"
        ;;

        of_get_ibm_chip_id)
            #
            # Determine if the of_get_ibm_chip_id() function is present.
            #
            # Added by commit b130e7c04f11 ("powerpc: export
            # of_get_ibm_chip_id function") in v4.2 (2015-05-07)
            #
            CODE="
            #include <linux/version.h>
            #if defined(NV_ASM_PROM_H_PRESENT)
            #include <asm/prom.h>
            #endif
            void conftest_of_get_ibm_chip_id(void) {
                #if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 2, 0)
                of_get_ibm_chip_id();
                #endif
            }"

            compile_check_conftest "$CODE" "NV_OF_GET_IBM_CHIP_ID_PRESENT" "" "functions"
        ;;

        drm_driver_unload_has_int_return_type)
            #
            # Determine if drm_driver::unload() returns integer value
            #
            # Changed to void by commit 11b3c20bdd15 ("drm: Change the return
            # type of the unload hook to void") in v4.11 (2017-01-06)
            #
            CODE="
            #if defined(NV_DRM_DRMP_H_PRESENT)
            #include <drm/drmP.h>
            #endif

            int conftest_drm_driver_unload_has_int_return_type(struct drm_driver *drv) {
                return drv->unload(NULL /* dev */);
            }"

            compile_check_conftest "$CODE" "NV_DRM_DRIVER_UNLOAD_HAS_INT_RETURN_TYPE" "" "types"
        ;;

        is_export_symbol_present_*)
            export_symbol_present_conftest $(echo $1 | cut -f5- -d_)
        ;;

        is_export_symbol_gpl_*)
            export_symbol_gpl_conftest $(echo $1 | cut -f5- -d_)
        ;;

        drm_atomic_helper_crtc_destroy_state_has_crtc_arg)
            #
            # Determine if __drm_atomic_helper_crtc_destroy_state() has 'crtc'
            # argument.
            #
            # 'crtc' argument removed by commit ec2dc6a0fe38 ("drm: Drop crtc
            # argument from __drm_atomic_helper_crtc_destroy_state") in v4.7
            # (2016-05-09)
            #
            CODE="
            #if defined(NV_DRM_DRM_ATOMIC_HELPER_H_PRESENT)
            #include <drm/drm_atomic_helper.h>
            #endif
            void conftest_drm_atomic_helper_crtc_destroy_state_has_crtc_arg(void) {
                __drm_atomic_helper_crtc_destroy_state(NULL, NULL);
            }"

            compile_check_conftest "$CODE" "NV_DRM_ATOMIC_HELPER_CRTC_DESTROY_STATE_HAS_CRTC_ARG" "" "types"
        ;;

        drm_atomic_helper_plane_destroy_state_has_plane_arg)
            #
            # Determine if __drm_atomic_helper_plane_destroy_state has
            # 'plane' argument.
            #
            # 'plane' argument removed by commit 2f701695fd3a (drm: Drop plane
            # argument from __drm_atomic_helper_plane_destroy_state") in v4.7
            # (2016-05-09)
            #
            CODE="
            #if defined(NV_DRM_DRM_ATOMIC_HELPER_H_PRESENT)
            #include <drm/drm_atomic_helper.h>
            #endif
            void conftest_drm_atomic_helper_plane_destroy_state_has_plane_arg(void) {
                __drm_atomic_helper_plane_destroy_state(NULL, NULL);
            }"

            compile_check_conftest "$CODE" "NV_DRM_ATOMIC_HELPER_PLANE_DESTROY_STATE_HAS_PLANE_ARG" "" "types"
        ;;

        drm_atomic_helper_connector_dpms)
            #
            # Determine if the function drm_atomic_helper_connector_dpms() is present.
            #
            # Removed by commit 7d902c05b480 ("drm: Nuke
            # drm_atomic_helper_connector_dpms") in v4.14 (2017-07-25)
            #
            CODE="
            #if defined(NV_DRM_DRM_ATOMIC_HELPER_H_PRESENT)
            #include <drm/drm_atomic_helper.h>
            #endif
            void conftest_drm_atomic_helper_connector_dpms(void) {
                drm_atomic_helper_connector_dpms();
            }"

            compile_check_conftest "$CODE" "NV_DRM_ATOMIC_HELPER_CONNECTOR_DPMS_PRESENT" "" "functions"
        ;;

        get_backlight_device_by_name)
            #
            # Determine if the get_backlight_device_by_name() function is present
            #
            CODE="
            #include <linux/backlight.h>
            int conftest_get_backlight_device_by_name(void) {
                return get_backlight_device_by_name();
            }"
            compile_check_conftest "$CODE" "NV_GET_BACKLIGHT_DEVICE_BY_NAME_PRESENT" "" "functions"
        ;;

        timer_setup)
            #
            # Determine if the function timer_setup() is present.
            #
            # Added by commit 686fef928bba ("timer: Prepare to change timer
            # callback argument type") in v4.14 (2017-09-28)
            #
            CODE="
            #include <linux/timer.h>
            int conftest_timer_setup(void) {
                return timer_setup();
            }"
            compile_check_conftest "$CODE" "NV_TIMER_SETUP_PRESENT" "" "functions"
        ;;

        radix_tree_replace_slot)
            #
            # Determine if the radix_tree_replace_slot() function is
            # present and how many arguments it takes.
            #
            # root parameter added to radix_tree_replace_slot (but the symbol
            # was not exported) by commit 6d75f366b924 ("lib: radix-tree:
            # check accounting of existing slot replacement users") in v4.10
            # (2016-12-12)
            #
            # radix_tree_replace_slot symbol export added by commit
            # 10257d719686 ("EXPORT_SYMBOL radix_tree_replace_slot") in v4.11
            # (2017-01-11)
            #
            CODE="
            #include <linux/radix-tree.h>
            #include <linux/version.h>
            void conftest_radix_tree_replace_slot(void) {
            #if (LINUX_VERSION_CODE < KERNEL_VERSION(4, 10, 0)) || (LINUX_VERSION_CODE >= KERNEL_VERSION(4, 11, 0))
                radix_tree_replace_slot();
            #endif
            }"
            compile_check_conftest "$CODE" "NV_RADIX_TREE_REPLACE_SLOT_PRESENT" "" "functions"

            echo "$CONFTEST_PREAMBLE
            #include <linux/radix-tree.h>
            void conftest_radix_tree_replace_slot(void) {
                radix_tree_replace_slot(NULL, NULL);
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                rm -f conftest$$.o
                echo "#define NV_RADIX_TREE_REPLACE_SLOT_ARGUMENT_COUNT 2" | append_conftest "functions"
                return
            fi

            echo "$CONFTEST_PREAMBLE
            #include <linux/radix-tree.h>
            void conftest_radix_tree_replace_slot(void) {
                radix_tree_replace_slot(NULL, NULL, NULL);
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                rm -f conftest$$.o
                echo "#define NV_RADIX_TREE_REPLACE_SLOT_ARGUMENT_COUNT 3" | append_conftest "functions"
                return
            else
                echo "#error radix_tree_replace_slot() conftest failed!" | append_conftest "functions"
            fi
        ;;

        cpumask_of_node)
            #
            # Determine whether cpumask_of_node is available.
            #
            # ARM support for cpumask_of_node() lagged until commit 1a2db300348b
            # ("arm64, numa: Add NUMA support for arm64 platforms.") in v4.7
            # (2016-04-08)
            #
            CODE="
            #include    <asm/topology.h>
            void conftest_cpumask_of_node(void) {
            (void)cpumask_of_node();
            }"

            compile_check_conftest "$CODE" "NV_CPUMASK_OF_NODE_PRESENT" "" "functions"
        ;;

        drm_mode_object_find_has_file_priv_arg)
            #
            # Determine if drm_mode_object_find() has 'file_priv' arguments.
            #
            # Updated to take 'file_priv' argument by commit 418da17214ac
            # ("drm: Pass struct drm_file * to __drm_mode_object_find [v2]")
            # in v4.15 (2017-03-14)
            #
            CODE="
            #include <drm/drm_mode_object.h>
            void conftest_drm_mode_object_find_has_file_priv_arg(
                    struct drm_device *dev,
                    struct drm_file *file_priv,
                    uint32_t id,
                    uint32_t type) {
                (void)drm_mode_object_find(dev, file_priv, id, type);
            }"

            compile_check_conftest "$CODE" "NV_DRM_MODE_OBJECT_FIND_HAS_FILE_PRIV_ARG" | append_conftest "types"
        ;;

        pci_enable_msix_range)
            #
            # Determine if the pci_enable_msix_range() function is present.
            #
            # Added by commit 302a2523c277 ("PCI/MSI: Add
            # pci_enable_msi_range() and pci_enable_msix_range()") in v3.14
            # (2013-12-30)
            #
            CODE="
            #include <linux/pci.h>
            void conftest_pci_enable_msix_range(void) {
                pci_enable_msix_range();
            }"

            compile_check_conftest "$CODE" "NV_PCI_ENABLE_MSIX_RANGE_PRESENT" "" "functions"
        ;;

        dma_buf_owner)
            #
            # Determine if the dma_buf struct has an owner member.
            #
            # Added by commit 9abdffe286c1 ("dma-buf: add ref counting for
            # module as exporter") in v4.2 (2015-05-05)
            #
            CODE="
            #include <linux/dma-buf.h>
            int conftest_dma_buf_owner(void) {
                return offsetof(struct dma_buf, owner);
            }"

            compile_check_conftest "$CODE" "NV_DMA_BUF_OWNER_PRESENT" "" "types"
        ;;

        dma_buf_export_args)
            #
            # Determine argument count for dma_buf_export().
            #
            # 4 arguments added by commit d15bd7ee445d
            # ("dma-buf: Introduce dma buffer sharing mechanism")
            # in v3.3 (2011-12-26)
            #
            # Additional argument added by commit 3aac4502fd3f
            # ("dma-buf: use reservation objects") in v3.17 (2014-07-01).
            #
            # Parameters wrapped in a single struct dma_buf_export_info by commit:
            # d8fbe341beb6("dma-buf: cleanup dma_buf_export() to make it easily extensible")
            # in v4.1 (2015-01-23).
            #
            echo "$CONFTEST_PREAMBLE
            #include <linux/dma-buf.h>
            struct dma_buf* conftest_dma_buf_export(void) {
                return dma_buf_export(NULL);
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                rm -f conftest$$.o
                echo "#define NV_DMA_BUF_EXPORT_ARGUMENT_COUNT 1" | append_conftest "functions"
                return
            fi

            echo "$CONFTEST_PREAMBLE
            #include <linux/dma-buf.h>
            struct dma_buf* conftest_dma_buf_export(void) {
                return dma_buf_export(NULL, NULL, 0, 0);
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                rm -f conftest$$.o
                echo "#define NV_DMA_BUF_EXPORT_ARGUMENT_COUNT 4" | append_conftest "functions"
                return
            fi

            echo "$CONFTEST_PREAMBLE
            #include <linux/dma-buf.h>
            struct dma_buf* conftest_dma_buf_export(void) {
                return dma_buf_export(NULL, NULL, 0, 0, NULL);
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                rm -f conftest$$.o
                echo "#define NV_DMA_BUF_EXPORT_ARGUMENT_COUNT 5" | append_conftest "functions"
                return
            fi
            echo "#error dma_buf_export() conftest failed!" | append_conftest "functions"
        ;;

        dma_buf_ops_has_kmap)
            #
            # Determine if .kmap exists in dma_buf_ops.
            # In some kernels, this is a mandatory callback.
            #
            # Added by commit fc13020e086b
            # ("dma-buf: add support for kernel cpu access") in v3.4 (2012-03-20)
            #
            echo "$CONFTEST_PREAMBLE
            #include <linux/dma-buf.h>
            int conftest_dma_buf_ops_has_kmap(void) {
                return offsetof(struct dma_buf_ops, kmap);
            }
            int conftest_dma_buf_ops_has_kunmap(void) {
                return offsetof(struct dma_buf_ops, kunmap);
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                echo "#define NV_DMA_BUF_OPS_HAS_KMAP" | append_conftest "types"
                rm -f conftest$$.o
                return
            else
                echo "#undef NV_DMA_BUF_OPS_HAS_KMAP" | append_conftest "types"
                return
            fi
        ;;

        dma_buf_ops_has_kmap_atomic)
            #
            # Determine if .kmap_atomic exists in dma_buf_ops.
            # In some kernels, this is a mandatory callback.
            #
            # Added by commit fc13020e086b
            # ("dma-buf: add support for kernel cpu access")in v3.4 (2012-03-20)
            #
            echo "$CONFTEST_PREAMBLE
            #include <linux/dma-buf.h>
            int conftest_dma_buf_ops_has_kmap_atomic(void) {
                return offsetof(struct dma_buf_ops, kmap_atomic);
            }
            int conftest_dma_buf_ops_has_kunmap_atomic(void) {
                return offsetof(struct dma_buf_ops, kunmap_atomic);
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                echo "#define NV_DMA_BUF_OPS_HAS_KMAP_ATOMIC" | append_conftest "types"
                rm -f conftest$$.o
                return
            else
                echo "#undef NV_DMA_BUF_OPS_HAS_KMAP_ATOMIC" | append_conftest "types"
                return
            fi
        ;;

        dma_buf_ops_has_map)
            #
            # Determine if .map exists in dma_buf_ops.
            # In some kernels, this is a mandatory callback.
            #
            # Added by commit f9b67f0014cb
            # ("dma-buf: Rename dma-ops to prevent conflict with kunmap_atomic macro")
            # in v4.12 (2017-04-19)
            #
            # Removed as a mandatory callback by commit f82aab2d521e
            # ("dma-buf: Remove requirement for ops->map() from dma_buf_export")
            # in v4.20 (2018-08-07)
            #
            # Completely removed from dma-buf by commit 4337ebbbbda3
            # ("dma-buf: Remove kernel map/unmap hooks") in v5.6 (2019-11-18)
            #
            echo "$CONFTEST_PREAMBLE
            #include <linux/dma-buf.h>
            int conftest_dma_buf_ops_has_map(void) {
                return offsetof(struct dma_buf_ops, map);
            }
            int conftest_dma_buf_ops_has_unmap(void) {
                return offsetof(struct dma_buf_ops, unmap);
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                echo "#define NV_DMA_BUF_OPS_HAS_MAP" | append_conftest "types"
                rm -f conftest$$.o
                return
            else
                echo "#undef NV_DMA_BUF_OPS_HAS_MAP" | append_conftest "types"
                return
            fi
        ;;

        dma_buf_ops_has_map_atomic)
            #
            # Determine if map_atomic/unmap_atomic exists in dma_buf_ops.
            # In some kernels, this is a mandatory callback.
            #
            # Added by commit f9b67f0014cb
            # ("dma-buf: Rename dma-ops to prevent conflict with kunmap_atomic macro")
            # in v4.12 (2017-04-19)
            #
            # Removed by commit f664a5269542
            # ("dma-buf: remove kmap_atomic interface") in v4.19 (2018-05-28)
            #
            echo "$CONFTEST_PREAMBLE
            #include <linux/dma-buf.h>
            int conftest_dma_buf_ops_has_map_atomic(void) {
                return offsetof(struct dma_buf_ops, map_atomic);
            }
            int conftest_dma_buf_ops_has_unmap_atomic(void) {
                return offsetof(struct dma_buf_ops, unmap_atomic);
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                echo "#define NV_DMA_BUF_OPS_HAS_MAP_ATOMIC" | append_conftest "types"
                rm -f conftest$$.o
                return
            else
                echo "#undef NV_DMA_BUF_OPS_HAS_MAP_ATOMIC" | append_conftest "types"
                return
            fi
        ;;

        dma_buf_has_dynamic_attachment)
            #
            # Determine if the function dma_buf_attachment_is_dynamic()
            # is present.
            #
            # Added by commit: 15fd552d186c
            # ("dma-buf: change DMA-buf locking convention v3") in v5.5 (2018-07-03)
            #
            echo "$CONFTEST_PREAMBLE
            #include <linux/dma-buf.h>
            bool conftest_dma_buf_attachment_is_dynamic(void) {
                return dma_buf_attachment_is_dynamic(NULL);
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                echo "#define NV_DMA_BUF_HAS_DYNAMIC_ATTACHMENT" | append_conftest "functions"
                rm -f conftest$$.o
                return
            else
                echo "#undef NV_DMA_BUF_HAS_DYNAMIC_ATTACHMENT" | append_conftest "functions"
                return
            fi
        ;;

        dma_buf_attachment_has_peer2peer)
            #
            # Determine if peer2peer is present in struct dma_buf_attachment.
            # peer2peer being true indicates that a dma-buf importer is able
            # to handle peer resources not backed by struct page.
            #
            # Added by commit: 09606b5446c2
            # ("dma-buf: add peer2peer flag") in v5.8 (2018-03-22)
            #
            echo "$CONFTEST_PREAMBLE
            #include <linux/dma-buf.h>
            int conftest_dma_buf_peer2peer(void) {
                return offsetof(struct dma_buf_attachment, peer2peer);
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                echo "#define NV_DMA_BUF_ATTACHMENT_HAS_PEER2PEER" | append_conftest "types"
                rm -f conftest$$.o
                return
            else
                echo "#undef NV_DMA_BUF_ATTACHMENT_HAS_PEER2PEER" | append_conftest "types"
                return
            fi
        ;;

        drm_connector_funcs_have_mode_in_name)
            #
            # Determine if _mode_ is present in connector function names.  We
            # only test drm_mode_connector_attach_encoder() and assume the
            # other functions are changed in sync.
            #
            # drm_mode_connector_attach_encoder() was renamed to
            # drm_connector_attach_encoder() by commit cde4c44d8769 ("drm:
            # drop _mode_ from drm_mode_connector_attach_encoder") in v4.19
            # (2018-07-09)
            #
            # drm_mode_connector_update_edid_property() was renamed by commit
            # c555f02371c3 ("drm: drop _mode_ from update_edit_property()")
            # in v4.19 (2018-07-09).
            #
            # The other DRM functions were renamed by commit 97e14fbeb53f
            # ("drm: drop _mode_ from remaining connector functions") in v4.19
            # (2018-07-09)
            #
            # Note that drm_connector.h by introduced by commit 522171951761
            # ("drm: Extract drm_connector.[hc]") in v4.9 (2016-08-12)
            #
            # Note: up to 4.9 function was provided by drm_crtc.h by commit
            # f453ba046074 in 2.6.29 (2008-12-29)
            #
            CODE="
            #if defined(NV_DRM_DRM_CONNECTOR_H_PRESENT)
            #include <drm/drm_connector.h>
            #endif
            #if defined(NV_DRM_DRM_CRTC_H_PRESENT)
            #include <drm/drm_crtc.h>
            #endif
            void conftest_drm_connector_funcs_have_mode_in_name(void) {
                drm_mode_connector_attach_encoder();
            }"

            compile_check_conftest "$CODE" "NV_DRM_CONNECTOR_FUNCS_HAVE_MODE_IN_NAME" "" "functions"
        ;;

        drm_connector_has_vrr_capable_property)
            #
            # Determine if drm_connector_attach_vrr_capable_property and
            # drm_connector_set_vrr_capable_property is present
            #
            # Added by commit ba1b0f6c73d4ea1390f0d5381f715ffa20c75f09 ("drm:
            # Add vrr_capable property to the drm connector") in v5.0-rc1
            # (2018-11-28)
            #
            CODE="
            #if defined(NV_DRM_DRM_CONNECTOR_H_PRESENT)
            #include <drm/drm_connector.h>
            #endif

            void conftest_drm_connector_has_vrr_capable_property(void) {
                drm_connector_attach_vrr_capable_property();
            }"

            compile_check_conftest "$CODE" "NV_DRM_CONNECTOR_HAS_VRR_CAPABLE_PROPERTY" "" "functions"
        ;;

        vm_fault_t)
            #
            # Determine if vm_fault_t is present
            #
            # Added by commit 1c8f422059ae5da07db7406ab916203f9417e396 ("mm:
            # change return type to vm_fault_t") in v4.17 (2018-04-05)
            #
            CODE="
            #include <linux/mm.h>
            vm_fault_t conftest_vm_fault_t;
            "
            compile_check_conftest "$CODE" "NV_VM_FAULT_T_IS_PRESENT" "" "types"
        ;;

        vmf_insert_pfn)
            #
            # Determine if the function vmf_insert_pfn() is
            # present.
            #
            # Added by commit 1c8f422059ae5da07db7406ab916203f9417e396 ("mm:
            # change return type to vm_fault_t") in v4.17 (2018-04-05)
            #
            CODE="
            #include <linux/mm.h>
            void conftest_vmf_insert_pfn(void) {
                vmf_insert_pfn();
            }"

            compile_check_conftest "$CODE" "NV_VMF_INSERT_PFN_PRESENT" "" "functions"
        ;;

        drm_framebuffer_get)
            #
            # Determine if the function drm_framebuffer_get() is present.
            #
            # Added by commit a4a69da06bc1 ("drm: Introduce
            # drm_framebuffer_{get,put}()") in v4.12 (2017-02-28).
            #
            CODE="
            #if defined(NV_DRM_DRMP_H_PRESENT)
            #include <drm/drmP.h>
            #endif

            #if defined(NV_DRM_DRM_FRAMEBUFFER_H_PRESENT)
            #include <drm/drm_framebuffer.h>
            #endif

            void conftest_drm_framebuffer_get(void) {
                drm_framebuffer_get();
            }"

            compile_check_conftest "$CODE" "NV_DRM_FRAMEBUFFER_GET_PRESENT" "" "functions"
        ;;

        drm_gem_object_get)
            #
            # Determine if the function drm_gem_object_get() is present.
            #
            # Added by commit e6b62714e87c ("drm: Introduce
            # drm_gem_object_{get,put}()") in v4.12 (2017-02-28).
            #
            CODE="
            #if defined(NV_DRM_DRMP_H_PRESENT)
            #include <drm/drmP.h>
            #endif

            #if defined(NV_DRM_DRM_GEM_H_PRESENT)
            #include <drm/drm_gem.h>
            #endif
            void conftest_drm_gem_object_get(void) {
                drm_gem_object_get();
            }"

            compile_check_conftest "$CODE" "NV_DRM_GEM_OBJECT_GET_PRESENT" "" "functions"
        ;;

        drm_dev_put)
            #
            # Determine if the function drm_dev_put() is present.
            #
            # Added by commit 9a96f55034e4 ("drm: introduce drm_dev_{get/put}
            # functions") in v4.15 (2017-09-26).
            #
            CODE="
            #if defined(NV_DRM_DRMP_H_PRESENT)
            #include <drm/drmP.h>
            #endif

            #if defined(NV_DRM_DRM_DRV_H_PRESENT)
            #include <drm/drm_drv.h>
            #endif
            void conftest_drm_dev_put(void) {
                drm_dev_put();
            }"

            compile_check_conftest "$CODE" "NV_DRM_DEV_PUT_PRESENT" "" "functions"
        ;;

        drm_connector_list_iter)
            #
            # Determine if the drm_connector_list_iter struct is present.
            #
            # Added by commit 613051dac40da1751ab269572766d3348d45a197 ("drm:
            # locking&new iterators for connector_list") in v4.11 (2016-12-14).
            #
            CODE="
            #include <drm/drm_connector.h>
            int conftest_drm_connector_list_iter(void) {
                struct drm_connector_list_iter conn_iter;
            }"

            compile_check_conftest "$CODE" "NV_DRM_CONNECTOR_LIST_ITER_PRESENT" "" "types"

            #
            # Determine if the function drm_connector_list_iter_get() is
            # renamed to drm_connector_list_iter_begin().
            #
            # Renamed by b982dab1e66d2b998e80a97acb6eaf56518988d3 (drm: Rename
            # connector list iterator API) in v4.12 (2017-02-28).
            #
            CODE="
            #if defined(NV_DRM_DRM_CONNECTOR_H_PRESENT)
            #include <drm/drm_connector.h>
            #endif
            void conftest_drm_connector_list_iter_begin(void) {
                drm_connector_list_iter_begin();
            }"

            compile_check_conftest "$CODE" "NV_DRM_CONNECTOR_LIST_ITER_BEGIN_PRESENT" "" "functions"
        ;;

        drm_atomic_helper_swap_state_has_stall_arg)
            #
            # Determine if drm_atomic_helper_swap_state() has 'stall' argument.
            #
            # drm_atomic_helper_swap_state() function prototype updated to take
            # 'state' and 'stall' arguments by commit
            # 5e84c2690b805caeff3b4c6c9564c7b8de54742d (drm/atomic-helper:
            # Massage swap_state signature somewhat)
            # in v4.8 (2016-06-10).
            #
            CODE="
            #include <drm/drm_atomic_helper.h>
            void conftest_drm_atomic_helper_swap_state_has_stall_arg(
                    struct drm_atomic_state *state,
                    bool stall) {
                (void)drm_atomic_helper_swap_state(state, stall);
            }"

            compile_check_conftest "$CODE" "NV_DRM_ATOMIC_HELPER_SWAP_STATE_HAS_STALL_ARG" | append_conftest "types"

            #
            # Determine if drm_atomic_helper_swap_state() returns int.
            #
            # drm_atomic_helper_swap_state() function prototype
            # updated to return int by commit
            # c066d2310ae9bbc695c06e9237f6ea741ec35e43 (drm/atomic: Change
            # drm_atomic_helper_swap_state to return an error.) in v4.14
            # (2017-07-11).
            #
            CODE="
            #include <drm/drm_atomic_helper.h>
            int conftest_drm_atomic_helper_swap_state_return_int(
                    struct drm_atomic_state *state,
                    bool stall) {
                return drm_atomic_helper_swap_state(state, stall);
            }"

            compile_check_conftest "$CODE" "NV_DRM_ATOMIC_HELPER_SWAP_STATE_RETURN_INT" | append_conftest "types"
        ;;

        pm_runtime_available)
            #
            # Determine if struct dev_pm_info has the 'usage_count' field.
            #
            # This was added to the kernel in commit 5e928f77a09a0 in v2.6.32
            # (2008-08-18), but originally were dependent on CONFIG_PM_RUNTIME,
            # which was folded into the more generic CONFIG_PM in commit
            # d30d819dc8310 in v3.19 (2014-11-27).
            # Rather than attempt to select the appropriate CONFIG option,
            # simply check if this member is present.
            #
            CODE="
            #include <linux/pm.h>
            void pm_runtime_conftest(void) {
                struct dev_pm_info dpmi;
                atomic_set(&dpmi.usage_count, 1);
            }"

            compile_check_conftest "$CODE" "NV_PM_RUNTIME_AVAILABLE" "" "generic"
        ;;

        dma_direct_map_resource)
            #
            # Determine whether dma_is_direct() exists.
            #
            # dma_is_direct() was added by commit 356da6d0cde3 ("dma-mapping:
            # bypass indirect calls for dma-direct") in 5.1 (2018-12-06).
            #
            # If dma_is_direct() does exist, then we assume that
            # dma_direct_map_resource() exists.  Both functions were added
            # as part of the same patchset.
            #
            # The presence of dma_is_direct() and dma_direct_map_resource()
            # means that dma_direct can perform DMA mappings itself.
            #
            CODE="
            #include <linux/dma-mapping.h>
            void conftest_dma_is_direct(void) {
                dma_is_direct();
            }"

            compile_check_conftest "$CODE" "NV_DMA_IS_DIRECT_PRESENT" "" "functions"
        ;;

        tegra_get_platform)
            #
            # Determine if tegra_get_platform() function is present
            #
            CODE="
            #if defined NV_SOC_TEGRA_CHIP_ID_H_PRESENT
            #include <soc/tegra/chip-id.h>
            #elif defined(NV_SOC_TEGRA_FUSE_H_PRESENT)
            #include <soc/tegra/fuse.h>
            #endif
            void conftest_tegra_get_platform(void) {
                tegra_get_platform(0);
            }
            "

            compile_check_conftest "$CODE" "NV_TEGRA_GET_PLATFORM_PRESENT" "" "functions"
        ;;

        tegra_bpmp_send_receive)
            #
            # Determine if tegra_bpmp_send_receive() function is present
            #
            CODE="
            #if defined NV_SOC_TEGRA_TEGRA_BPMP_H_PRESENT
            #include <soc/tegra/tegra_bpmp.h>
            #endif
            int conftest_tegra_bpmp_send_receive(
                    int mrq,
                    void *ob_data,
                    int ob_sz,
                    void *ib_data,
                    int ib_sz) {
                return tegra_bpmp_send_receive(mrq, ob_data, ob_sz, ib_data, ib_sz);
            }
            "

            compile_check_conftest "$CODE" "NV_TEGRA_BPMP_SEND_RECEIVE" "" "functions"
        ;;

        cmd_uphy_display_port_init)
            #
            # Determine if CMD_UPHY_DISPLAY_PORT_INIT enum present in bpmp-abi header
            # This enum is used only in Tegra down-stream kernel.
            #
            CODE="
            #include <stdint.h>
            #include <soc/tegra/bpmp-abi.h>

            int conftest_cmd_uphy_display_port_init(void) {
                return CMD_UPHY_DISPLAY_PORT_INIT;
            }
            "
            compile_check_conftest "$CODE" "NV_CMD_UPHY_DISPLAY_PORT_INIT_PRESENT" "" "generic"

        ;;

        cmd_uphy_display_port_off)
            #
            # Determine if CMD_UPHY_DISPLAY_PORT_OFF enum present in bpmp-abi header
            # This enum is used only in Tegra down-stream kernel.
            #
            CODE="
            #include <stdint.h>
            #include <soc/tegra/bpmp-abi.h>

            int conftest_cmd_uphy_display_port_off(void) {
                return CMD_UPHY_DISPLAY_PORT_OFF;
            }
            "
            compile_check_conftest "$CODE" "NV_CMD_UPHY_DISPLAY_PORT_OFF_PRESENT" "" "generic"

        ;;

        drm_alpha_blending_available)
            #
            # Determine if the DRM subsystem supports alpha blending
            #
            # This conftest using "generic" rather than "functions" because
            # with the logic of "functions" the presence of
            # *either*_alpha_property or _blend_mode_property would be enough
            # to cause NV_DRM_ALPHA_BLENDING_AVAILABLE to be defined.
            #
            CODE="
            #if defined(NV_DRM_DRM_BLEND_H_PRESENT)
            #include <drm/drm_blend.h>
            #endif
            void conftest_drm_alpha_blending_available(void) {
                /* 2018-04-11 ae0e28265e216dad11d4cbde42fc15e92919af78 */
                (void)drm_plane_create_alpha_property;

                /* 2018-08-23 a5ec8332d4280500544e316f76c04a7adc02ce03 */
                (void)drm_plane_create_blend_mode_property;
            }"

            compile_check_conftest "$CODE" "NV_DRM_ALPHA_BLENDING_AVAILABLE" "" "generic"
        ;;

        drm_rotation_available)
            #
            # Determine if the DRM subsystem supports rotation.
            #
            # drm_plane_create_rotation_property() was added on 2016-09-26 by
            # d138dd3c0c70979215f3184cf36f95875e37932e (drm: Add support for
            # optional per-plane rotation property) in linux kernel. Presence
            # of it is sufficient to say that DRM subsystem support rotation.
            #
            CODE="
            #if defined(NV_DRM_DRM_BLEND_H_PRESENT)
            #include <drm/drm_blend.h>
            #endif
            void conftest_drm_rotation_available(void) {
                drm_plane_create_rotation_property();
            }"

            compile_check_conftest "$CODE" "NV_DRM_ROTATION_AVAILABLE" "" "functions"
            ;;

        drm_driver_prime_flag_present)
            #
            # Determine whether driver feature flag DRIVER_PRIME is present.
            #
            # The DRIVER_PRIME flag was added by commit 3248877ea179 (drm:
            # base prime/dma-buf support (v5)) in v3.4 (2011-11-25) and is
            # removed by commit 0424fdaf883a (drm/prime: Actually remove
            # DRIVER_PRIME everywhere) on 2019-06-17.
            #
            # DRIVER_PRIME definition moved from drmP.h to drm_drv.h by
            # commit 85e634bce01a (drm: Extract drm_drv.h) in v4.10
            # (2016-11-14).
            #
            # DRIVER_PRIME define is changed to enum value by commit
            # 0e2a933b02c9 (drm: Switch DRIVER_ flags to an enum) in v5.1
            # (2019-01-29).
            #
            CODE="
            #if defined(NV_DRM_DRMP_H_PRESENT)
            #include <drm/drmP.h>
            #endif

            #if defined(NV_DRM_DRM_DRV_H_PRESENT)
            #include <drm/drm_drv.h>
            #endif

            unsigned int drm_driver_prime_flag_present_conftest(void) {
                return DRIVER_PRIME;
            }"

            compile_check_conftest "$CODE" "NV_DRM_DRIVER_PRIME_FLAG_PRESENT" "" "types"
        ;;

        drm_connector_for_each_possible_encoder)
            #
            # Determine the number of arguments of the
            # drm_connector_for_each_possible_encoder() macro.
            #
            # drm_connector_for_each_possible_encoder() is added by commit
            # 83aefbb887b5 (drm: Add drm_connector_for_each_possible_encoder())
            # in v4.19. The definition and prorotype is changed to take only
            # two arguments connector and encoder, by commit 62afb4ad425a
            # (drm/connector: Allow max possible encoders to attach to a
            # connector) in v5.5rc1.
            #
            echo "$CONFTEST_PREAMBLE
            #if defined(NV_DRM_DRMP_H_PRESENT)
            #include <drm/drmP.h>
            #endif

            #if defined(NV_DRM_DRM_CONNECTOR_H_PRESENT)
            #include <drm/drm_connector.h>
            #endif

            void conftest_drm_connector_for_each_possible_encoder(
                struct drm_connector *connector,
                struct drm_encoder *encoder,
                int i) {

                drm_connector_for_each_possible_encoder(connector, encoder, i) {
                }
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                echo "#define NV_DRM_CONNECTOR_FOR_EACH_POSSIBLE_ENCODER_ARGUMENT_COUNT 3" | append_conftest "functions"
                rm -f conftest$$.o
                return
            else
                echo "#define NV_DRM_CONNECTOR_FOR_EACH_POSSIBLE_ENCODER_ARGUMENT_COUNT 2" | append_conftest "functions"
            fi
        ;;

        mmu_notifier_ops_invalidate_range)
            #
            # Determine if the mmu_notifier_ops struct has the
            # 'invalidate_range' member.
            #
            # struct mmu_notifier_ops.invalidate_range was added by commit
            # 0f0a327fa12cd55de5e7f8c05a70ac3d047f405e ("mmu_notifier: add the
            # callback for mmu_notifier_invalidate_range()") in v3.19
            # (2014-11-13).
            CODE="
            #include <linux/mmu_notifier.h>
            int conftest_mmu_notifier_ops_invalidate_range(void) {
                return offsetof(struct mmu_notifier_ops, invalidate_range);
            }"

            compile_check_conftest "$CODE" "NV_MMU_NOTIFIER_OPS_HAS_INVALIDATE_RANGE" "" "types"
        ;;

        drm_format_num_planes)
            #
            # Determine if drm_format_num_planes() function is present.
            #
            # The drm_format_num_planes() function was added by commit
            # d0d110e09629 drm: Add drm_format_num_planes() utility function in
            # v3.3 (2011-12-20). Prototype was moved from drm_crtc.h to
            # drm_fourcc.h by commit ae4df11a0f53 (drm: Move format-related
            # helpers to drm_fourcc.c) in v4.8 (2016-06-09).
            # drm_format_num_planes() has been removed by commit 05c452c115bf
            # (drm: Remove users of drm_format_num_planes) removed v5.3
            # (2019-05-16).
            #
            CODE="

            #if defined(NV_DRM_DRM_CRTC_H_PRESENT)
            #include <drm/drm_crtc.h>
            #endif

            #if defined(NV_DRM_DRM_FOURCC_H_PRESENT)
            #include <drm/drm_fourcc.h>
            #endif

            void conftest_drm_format_num_planes(void) {
                drm_format_num_planes();
            }
            "

            compile_check_conftest "$CODE" "NV_DRM_FORMAT_NUM_PLANES_PRESENT" "" "functions"
        ;;

        drm_gem_object_has_resv)
            #
            # Determine if the 'drm_gem_object' structure has a 'resv' field.
            #
            # A 'resv' filed in the 'drm_gem_object' structure, is added by
            # commit 1ba627148ef5 (drm: Add reservation_object to
            # drm_gem_object) in v5.2.
            #
            CODE="$CONFTEST_PREAMBLE
            #if defined(NV_DRM_DRM_GEM_H_PRESENT)
            #include <drm/drm_gem.h>
            #endif

            int conftest_drm_gem_object_has_resv(void) {
                return offsetof(struct drm_gem_object, resv);
            }"

            compile_check_conftest "$CODE" "NV_DRM_GEM_OBJECT_HAS_RESV" "" "types"
        ;;

        proc_ops)
            #
            # Determine if the 'struct proc_ops' type is present.
            #
            # Added by commit d56c0d45f0e2 ("proc: decouple proc from VFS with
            # "struct proc_ops"") in 5.6-rc1
            #
            CODE="
            #include <linux/proc_fs.h>

            struct proc_ops p_ops;
            "

            compile_check_conftest "$CODE" "NV_PROC_OPS_PRESENT" "" "types"
        ;;

        drm_crtc_state_has_async_flip)
            #
            # Determine if the 'drm_crtc_state' structure has a 'async_flip'
            # field.
            #
            # Commit 4d85f45c73a2 (drm/atomic: Rename crtc_state->pageflip_flags
            # to async_flip) replaced 'pageflip_flags' by 'async_flip' in v5.4.
            #
            CODE="
            #if defined(NV_DRM_DRM_CRTC_H_PRESENT)
            #include <drm/drm_crtc.h>
            #endif

            int conftest_drm_crtc_state_has_async_flip(void) {
                return offsetof(struct drm_crtc_state, async_flip);
            }"

            compile_check_conftest "$CODE" "NV_DRM_CRTC_STATE_HAS_ASYNC_FLIP" "" "types"
        ;;

        drm_crtc_state_has_pageflip_flags)
            #
            # Determine if the 'drm_crtc_state' structure has a
            # 'pageflip_flags' field.
            #
            # 'pageflip_flags' added by commit 6cbe5c466d73 (drm/atomic: Save
            # flip flags in drm_crtc_state) in v4.12. Commit 4d85f45c73a2
            # (drm/atomic: Rename crtc_state->pageflip_flags to async_flip)
            # replaced 'pageflip_flags' by 'async_flip' in v5.4.
            #
            CODE="
            #if defined(NV_DRM_DRM_CRTC_H_PRESENT)
            #include <drm/drm_crtc.h>
            #endif

            int conftest_drm_crtc_state_has_pageflip_flags(void) {
                return offsetof(struct drm_crtc_state, pageflip_flags);
            }"

            compile_check_conftest "$CODE" "NV_DRM_CRTC_STATE_HAS_PAGEFLIP_FLAGS" "" "types"
        ;;

        drm_crtc_state_has_vrr_enabled)
            #
            # Determine if 'drm_crtc_state' structure has a
            # 'vrr_enabled' field.
            #
            # Added by commit 1398958cfd8d331342d657d37151791dd7256b40 ("drm:
            # Add vrr_enabled property to drm CRTC") in v5.0-rc1 (2018-11-28)
            #
            CODE="
            #if defined(NV_DRM_DRM_CRTC_H_PRESENT)
            #include <drm/drm_crtc.h>
            #endif

            int conftest_drm_crtc_state_has_vrr_enabled(void) {
                return offsetof(struct drm_crtc_state, vrr_enabled);
            }"

            compile_check_conftest "$CODE" "NV_DRM_CRTC_STATE_HAS_VRR_ENABLED" "" "types"
        ;;

        ktime_get_raw_ts64)
            #
            # Determine if ktime_get_raw_ts64() is present
            #
            # Added by commit fb7fcc96a86cf ("timekeeping: Standardize on
            # ktime_get_*() naming") in 4.18 (2018-04-27)
            #
        CODE="
        #include <linux/ktime.h>
        void conftest_ktime_get_raw_ts64(void){
            ktime_get_raw_ts64();
        }"
            compile_check_conftest "$CODE" "NV_KTIME_GET_RAW_TS64_PRESENT" "" "functions"
        ;;

        ktime_get_real_ts64)
            #
            # Determine if ktime_get_real_ts64() is present
            #
            # Added by commit d6d29896c665d ("timekeeping: Provide timespec64
            # based interfaces") in 3.17 (2014-07-16)
            #
        CODE="
        #include <linux/ktime.h>
        void conftest_ktime_get_real_ts64(void){
            ktime_get_real_ts64();
        }"
            compile_check_conftest "$CODE" "NV_KTIME_GET_REAL_TS64_PRESENT" "" "functions"
        ;;

        drm_format_modifiers_present)
            #
            # Determine whether the base DRM format modifier support is present.
            #
            # This will show up in a few places:
            #
            # -Definition of the format modifier constructor macro, which
            #  we can use to reconstruct our bleeding-edge format modifiers
            #  when the local kernel headers don't include them.
            #
            # -The first set of format modifier vendor macros, including the
            #  poorly named "NV" vendor, which was later renamed "NVIDIA".
            #
            # -the "modifier[]" member of the AddFB2 ioctl's parameter
            #  structure.
            #
            # All these were added by commit e3eb3250d84e (drm: add support for
            # tiled/compressed/etc modifier in addfb2) in 4.1-rc1 (2015-02-05).
            CODE="
            #include <drm/drm_mode.h>
            #include <drm/drm_fourcc.h>
            int conftest_fourcc_fb_modifiers(void) {
                u64 my_fake_mod = fourcc_mod_code(INTEL, 0);
                (void)my_fake_mod;
                return offsetof(struct drm_mode_fb_cmd2, modifier);
            }"

            compile_check_conftest "$CODE" "NV_DRM_FORMAT_MODIFIERS_PRESENT" "" "types"

        ;;

        timespec64)
            #
            # Determine if struct timespec64 is present
            # Added by commit 361a3bf00582 ("time64: Add time64.h header and
            # define struct timespec64") in 3.17 (2014-07-16)
            #
        CODE="
        #include <linux/time.h>

        struct timespec64 ts64;
        "
            compile_check_conftest "$CODE" "NV_TIMESPEC64_PRESENT" "" "types"

        ;;

        vmalloc_has_pgprot_t_arg)
            #
            # Determine if __vmalloc has the 'pgprot' argument.
            #
            # The third argument to __vmalloc, page protection
            # 'pgprot_t prot', was removed by commit 88dca4ca5a93
            # (mm: remove the pgprot argument to __vmalloc)
            # in v5.8-rc1 (2020-06-01).
        CODE="
        #include <linux/vmalloc.h>

        void conftest_vmalloc_has_pgprot_t_arg(void) {
            pgprot_t prot;
            (void)__vmalloc(0, 0, prot);
        }"

            compile_check_conftest "$CODE" "NV_VMALLOC_HAS_PGPROT_T_ARG" "" "types"

        ;;

        mm_has_mmap_lock)
            #
            # Determine if the 'mm_struct' structure has a 'mmap_lock' field.
            #
            # Kernel commit da1c55f1b272 ("mmap locking API: rename mmap_sem
            # to mmap_lock") replaced the field 'mmap_sem' by 'mmap_lock'
            # in v5.8-rc1 (2020-06-08).
            CODE="
            #include <linux/mm_types.h>

            int conftest_mm_has_mmap_lock(void) {
                return offsetof(struct mm_struct, mmap_lock);
            }"

            compile_check_conftest "$CODE" "NV_MM_HAS_MMAP_LOCK" "" "types"
        ;;

        full_name_hash)
            #
            # Determine how many arguments full_name_hash takes.
            #
            # Changed by commit 8387ff2577e ("vfs: make the string hashes salt
            # the hash") in v4.8 (2016-06-10)
            #
            echo "$CONFTEST_PREAMBLE
            #include <linux/stringhash.h>
            void conftest_full_name_hash(void) {
                full_name_hash(NULL, NULL, 0);
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                rm -f conftest$$.o
                echo "#define NV_FULL_NAME_HASH_ARGUMENT_COUNT 3" | append_conftest "functions"
            else
                echo "#define NV_FULL_NAME_HASH_ARGUMENT_COUNT 2" | append_conftest "functions"
            fi
        ;;

        drm_vma_offset_exact_lookup_locked)
            #
            # Determine if the drm_vma_offset_exact_lookup_locked() function
            # is present.
            #
            # Added by commit 2225cfe46bcc ("drm/gem: Use kref_get_unless_zero
            # for the weak mmap references") in v4.4
            #
            CODE="
            #include <drm/drm_vma_manager.h>
            void conftest_drm_vma_offset_exact_lookup_locked(void) {
                drm_vma_offset_exact_lookup_locked();
            }"

            compile_check_conftest "$CODE" "NV_DRM_VMA_OFFSET_EXACT_LOOKUP_LOCKED_PRESENT" "" "functions"
        ;;

        drm_vma_node_is_allowed_has_tag_arg)
            #
            # Determine if drm_vma_node_is_allowed() has 'tag' arguments of
            # 'struct drm_file *' type.
            #
            # Updated to take 'tag' argument by commit d9a1f0b4eb60 ("drm: use
            # drm_file to tag vm-bos") in v4.9
            #
            CODE="
            #include <drm/drm_vma_manager.h>
            bool drm_vma_node_is_allowed(struct drm_vma_offset_node *node,
                                         struct drm_file *tag) {
                return true;
            }"

            compile_check_conftest "$CODE" "NV_DRM_VMA_NODE_IS_ALLOWED_HAS_TAG_ARG" | append_conftest "types"
        ;;

        drm_vma_offset_node_has_readonly)
            #
            # Determine if the 'drm_vma_offset_node' structure has a 'readonly'
            # field.
            #
            # Added by commit 3e977ac6179b ("drm/i915: Prevent writing into a
            # read-only object via a GGTT mmap") in v4.19.
            #
            CODE="
            #include <drm/drm_vma_manager.h>

            int conftest_drm_vma_offset_node_has_readonly(void) {
                return offsetof(struct drm_vma_offset_node, readonly);
            }"

            compile_check_conftest "$CODE" "NV_DRM_VMA_OFFSET_NODE_HAS_READONLY" "" "types"

        ;;

        pci_enable_atomic_ops_to_root)
            # pci_enable_atomic_ops_to_root was added by
            # commit 430a23689dea ("PCI: Add pci_enable_atomic_ops_to_root()")
            # in v4.16-rc1 (2018-01-05)
            #
            CODE="
            #include <linux/pci.h>
            void conftest_pci_enable_atomic_ops_to_root(void) {
                pci_enable_atomic_ops_to_root();
            }"
            compile_check_conftest "$CODE" "NV_PCI_ENABLE_ATOMIC_OPS_TO_ROOT_PRESENT" "" "functions"
        ;;

        kvmalloc)
            #
            # Determine if kvmalloc() is present
            #
            # Added by commit a7c3e901a46ff54c016d040847eda598a9e3e653 ("mm:
            # introduce kv[mz]alloc helpers") in v4.12 (2017-05-08).
            #
        CODE="
        #include <linux/mm.h>
        void conftest_kvmalloc(void){
            kvmalloc();
        }"
            compile_check_conftest "$CODE" "NV_KVMALLOC_PRESENT" "" "functions"

        ;;

        drm_gem_object_put_unlocked)
            #
            # Determine if the function drm_gem_object_put_unlocked() is present.
            #
            # In v5.9-rc1, commit 2f4dd13d4bb8 ("drm/gem: add
            # drm_gem_object_put helper") removes drm_gem_object_put_unlocked()
            # function and replace its definition by transient macro. Commit
            # ab15d56e27be ("drm: remove transient
            # drm_gem_object_put_unlocked()") finally removes
            # drm_gem_object_put_unlocked() macro.
            #
            CODE="
            #if defined(NV_DRM_DRMP_H_PRESENT)
            #include <drm/drmP.h>
            #endif

            #if defined(NV_DRM_DRM_GEM_H_PRESENT)
            #include <drm/drm_gem.h>
            #endif
            void conftest_drm_gem_object_put_unlocked(void) {
                drm_gem_object_put_unlocked();
            }"

            compile_check_conftest "$CODE" "NV_DRM_GEM_OBJECT_PUT_UNLOCK_PRESENT" "" "functions"
        ;;

        drm_display_mode_has_vrefresh)
            #
            # Determine if the 'drm_display_mode' structure has a 'vrefresh'
            # field.
            #
            # Removed by commit 0425662fdf05 ("drm: Nuke mode->vrefresh") in
            # v5.9-rc1.
            #
            CODE="
            #include <drm/drm_modes.h>

            int conftest_drm_display_mode_has_vrefresh(void) {
                return offsetof(struct drm_display_mode, vrefresh);
            }"

            compile_check_conftest "$CODE" "NV_DRM_DISPLAY_MODE_HAS_VREFRESH" "types"

        ;;

        drm_driver_master_set_has_int_return_type)
            #
            # Determine if drm_driver::master_set() returns integer value
            #
            # Changed to void by commit 907f53200f98 ("drm: vmwgfx: remove
            # drm_driver::master_set() return type") in v5.9-rc1.
            #
            CODE="
            #if defined(NV_DRM_DRMP_H_PRESENT)
            #include <drm/drmP.h>
            #endif

            #if defined(NV_DRM_DRM_DRV_H_PRESENT)
            #include <drm/drm_drv.h>
            #endif

            int conftest_drm_driver_master_set_has_int_return_type(struct drm_driver *drv,
                struct drm_device *dev, struct drm_file *file_priv, bool from_open) {

                return drv->master_set(dev, file_priv, from_open);
            }"

            compile_check_conftest "$CODE" "NV_DRM_DRIVER_SET_MASTER_HAS_INT_RETURN_TYPE" "" "types"
        ;;

        drm_driver_has_gem_free_object)
            #
            # Determine if the 'drm_driver' structure has a 'gem_free_object'
            # function pointer.
            #
            # drm_driver::gem_free_object is removed by commit 1a9458aeb8eb
            # ("drm: remove drm_driver::gem_free_object") in v5.9-rc1.
            #
            CODE="
            #if defined(NV_DRM_DRMP_H_PRESENT)
            #include <drm/drmP.h>
            #endif

            #if defined(NV_DRM_DRM_DRV_H_PRESENT)
            #include <drm/drm_drv.h>
            #endif

            int conftest_drm_driver_has_gem_free_object(void) {
                return offsetof(struct drm_driver, gem_free_object);
            }"

            compile_check_conftest "$CODE" "NV_DRM_DRIVER_HAS_GEM_FREE_OBJECT" "" "types"
        ;;

        vga_tryget)
            #
            # Determine if vga_tryget() is present
            #
            # vga_tryget() was removed by commit f369bc3f9096 ("vgaarb: mark
            # vga_tryget static") in v5.9-rc1 (2020-08-01).
            #
            CODE="
            #include <linux/vgaarb.h>
            void conftest_vga_tryget(void) {
                vga_tryget();
            }"

            compile_check_conftest "$CODE" "NV_VGA_TRYGET_PRESENT" "" "functions"
        ;;

        pci_channel_state)
            #
            # Determine if pci_channel_state enum type is present.
            #
            # pci_channel_state was removed by commit 16d79cd4e23b ("PCI: Use
            # 'pci_channel_state_t' instead of 'enum pci_channel_state'") in
            # v5.9-rc1 (2020-07-02).
            #
            CODE="
            #include <linux/pci.h>

            enum pci_channel_state state;
            "

            compile_check_conftest "$CODE" "NV_PCI_CHANNEL_STATE_PRESENT" "" "types"
        ;;

        cc_platform_has)
            #
            # Determine if 'cc_platform_has()' is present.
            #
            # Added by commit aa5a461171f9 ("x86/sev: Add an x86 version of
            # cc_platform_has()") in v5.15.3 (2021-10-04)
            CODE="
            #if defined(NV_LINUX_CC_PLATFORM_H_PRESENT)
            #include <linux/cc_platform.h>
            #endif

            void conftest_cc_platfrom_has(void) {
                cc_platform_has();
            }"

            compile_check_conftest "$CODE" "NV_CC_PLATFORM_PRESENT" "" "functions"
        ;;

        drm_prime_pages_to_sg_has_drm_device_arg)
            #
            # Determine if drm_prime_pages_to_sg() has 'dev' argument.
            #
            # drm_prime_pages_to_sg() is updated to take 'dev' argument by commit
            # 707d561f77b5 ("drm: allow limiting the scatter list size.").
            #
            CODE="
            #if defined(NV_DRM_DRMP_H_PRESENT)
            #include <drm/drmP.h>
            #endif
            #if defined(NV_DRM_DRM_PRIME_H_PRESENT)
            #include <drm/drm_prime.h>
            #endif

            struct sg_table *drm_prime_pages_to_sg(struct drm_device *dev,
                                                   struct page **pages,
                                                   unsigned int nr_pages) {
                return 0;
            }"

            compile_check_conftest "$CODE" "NV_DRM_PRIME_PAGES_TO_SG_HAS_DRM_DEVICE_ARG" "" "types"
        ;;

        drm_driver_has_gem_prime_callbacks)
            #
            # Determine if drm_driver structure has the GEM and PRIME callback
            # function pointers.
            #
            # The GEM and PRIME callback are removed from drm_driver
            # structure, by commit d693def4fd1c ("drm: Remove obsolete GEM and
            # PRIME callbacks from struct drm_driver").
            #
            CODE="
            #if defined(NV_DRM_DRMP_H_PRESENT)
            #include <drm/drmP.h>
            #endif

            #if defined(NV_DRM_DRM_DRV_H_PRESENT)
            #include <drm/drm_drv.h>
            #endif

            void conftest_drm_driver_has_gem_and_prime_callbacks(void) {
                struct drm_driver drv;

                drv.gem_prime_pin = 0;
                drv.gem_prime_get_sg_table = 0;
                drv.gem_prime_vmap = 0;
                drv.gem_prime_vunmap = 0;
                drv.gem_vm_ops = 0;
            }"

            compile_check_conftest "$CODE" "NV_DRM_DRIVER_HAS_GEM_PRIME_CALLBACKS" "" "types"
        ;;

        drm_crtc_atomic_check_has_atomic_state_arg)
            #
            # Determine if drm_crtc_helper_funcs::atomic_check takes 'state'
            # argument of 'struct drm_atomic_state' type.
            #
            # The commit 29b77ad7b9ca ("drm/atomic: Pass the full state to CRTC
            # atomic_check") passed the full atomic state to
            # drm_crtc_helper_funcs::atomic_check()
            #
            # To test the signature of drm_crtc_helper_funcs::atomic_check(),
            # declare a function prototype with typeof ::atomic_check(), and then
            # define the corresponding function implementation with the expected
            # signature.  Successful compilation indicates that ::atomic_check()
            # has the expected signature.
            #
            echo "$CONFTEST_PREAMBLE
            #include <drm/drm_modeset_helper_vtables.h>

            static const struct drm_crtc_helper_funcs *funcs;
            typeof(*funcs->atomic_check) conftest_drm_crtc_atomic_check_has_atomic_state_arg;

            int conftest_drm_crtc_atomic_check_has_atomic_state_arg(
                    struct drm_crtc *crtc, struct drm_atomic_state *state) {
                return 0;
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                rm -f conftest$$.o
                echo "#define NV_DRM_CRTC_ATOMIC_CHECK_HAS_ATOMIC_STATE_ARG" | append_conftest "types"
            else
                echo "#undef NV_DRM_CRTC_ATOMIC_CHECK_HAS_ATOMIC_STATE_ARG" | append_conftest "types"
            fi
        ;;

        drm_gem_object_vmap_has_map_arg)
            #
            # Determine if drm_gem_object_funcs::vmap takes 'map'
            # argument of 'struct dma_buf_map' type.
            #
            # The commit 49a3f51dfeee ("drm/gem: Use struct dma_buf_map in GEM
            # vmap ops and convert GEM backends") update
            # drm_gem_object_funcs::vmap to take 'map' argument.
            #
            CODE="
            #include <drm/drm_gem.h>
            int conftest_drm_gem_object_vmap_has_map_arg(
                    struct drm_gem_object *obj, struct dma_buf_map *map) {
                return obj->funcs->vmap(obj, map);
            }"

            compile_check_conftest "$CODE" "NV_DRM_GEM_OBJECT_VMAP_HAS_MAP_ARG" "" "types"
        ;;

        seq_read_iter)
            #
            # Determine if seq_read_iter() is present
            #
            # seq_read_iter() was added by commit d4d50710a8b4 ("seq_file:
            # add seq_read_iter") in v5.10-rc1 (2020-11-04).
            #
            CODE="
            #include <linux/seq_file.h>
            void conftest_seq_read_iter(void) {
                seq_read_iter();
            }"

            compile_check_conftest "$CODE" "NV_SEQ_READ_ITER_PRESENT" "" "functions"
        ;;

        pci_class_multimedia_hd_audio)
            #
            # Determine if 'PCI_CLASS_MULTIMEDIA_HD_AUDIO' macro is present
            # in <linux/pci_ids.h>.
            #
            # The commit 07f4f97d7b4b ("vga_switcheroo: Use device link for HDA
            # controller") has moved 'PCI_CLASS_MULTIMEDIA_HD_AUDIO' macro from
            # <sound/hdaudio.h> to <linux/pci_ids.h> in v4.17-rc1 (2018-03-03).
            #
            CODE="
            #include <linux/pci_ids.h>
            unsigned int conftest_pci_class_multimedia_hd_audio(void) {
                return PCI_CLASS_MULTIMEDIA_HD_AUDIO;
            }"

            compile_check_conftest "$CODE" "NV_PCI_CLASS_MULTIMEDIA_HD_AUDIO_PRESENT" "" "generic"
        ;;

        unsafe_follow_pfn)
            #
            # Determine if unsafe_follow_pfn() is present.
            #
            # unsafe_follow_pfn() was added by commit 69bacee7f9ad
            # ("mm: Add unsafe_follow_pfn") in v5.13-rc1.
            #
            CODE="
            #include <linux/mm.h>
            void conftest_unsafe_follow_pfn(void) {
                unsafe_follow_pfn();
            }"

            compile_check_conftest "$CODE" "NV_UNSAFE_FOLLOW_PFN_PRESENT" "" "functions"
        ;;

        drm_plane_atomic_check_has_atomic_state_arg)
            #
            # Determine if drm_plane_helper_funcs::atomic_check takes 'state'
            # argument of 'struct drm_atomic_state' type.
            #
            # The commit 7c11b99a8e58 ("drm/atomic: Pass the full state to
            # planes atomic_check") passed the full atomic state to
            # drm_plane_helper_funcs::atomic_check()
            #
            # To test the signature of drm_plane_helper_funcs::atomic_check(),
            # declare a function prototype with typeof ::atomic_check(), and then
            # define the corresponding function implementation with the expected
            # signature.  Successful compilation indicates that ::atomic_check()
            # has the expected signature.
            #
            echo "$CONFTEST_PREAMBLE
            #include <drm/drm_modeset_helper_vtables.h>

            static const struct drm_plane_helper_funcs *funcs;
            typeof(*funcs->atomic_check) conftest_drm_plane_atomic_check_has_atomic_state_arg;

            int conftest_drm_plane_atomic_check_has_atomic_state_arg(
                    struct drm_plane *plane, struct drm_atomic_state *state) {
                return 0;
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                rm -f conftest$$.o
                echo "#define NV_DRM_PLANE_ATOMIC_CHECK_HAS_ATOMIC_STATE_ARG" | append_conftest "types"
            else
                echo "#undef NV_DRM_PLANE_ATOMIC_CHECK_HAS_ATOMIC_STATE_ARG" | append_conftest "types"
            fi
        ;;

        ib_peer_memory_symbols)
            #
            # Determine if the following symbols exist in Module.symvers:
            # 1. ib_register_peer_memory_client
            # 2. ib_unregister_peer_memory_client
            # The conftest first checks in the kernel's own Module.symvers in
            # the regular path. If the symbols are not found there, it's possible
            # that MOFED is installed and check for these symbols in MOFED's
            # Module.symvers whose path is different from the kernel's symvers.
            #
            # Note: KERNELRELEASE and ARCH are defined by Kbuild and automatically
            # passed down to conftest.sh as env vars.

            MLNX_OFED_KERNEL_DIR=/usr/src/ofa_kernel
            VAR_DKMS_SOURCES_DIR=$(test -d /var/lib/dkms/mlnx-ofed-kernel &&
                                   ls -d /var/lib/dkms/mlnx-ofed-kernel/*/build 2>/dev/null)

            if check_for_ib_peer_memory_symbols "$OUTPUT" || \
               check_for_ib_peer_memory_symbols "$MLNX_OFED_KERNEL_DIR/$ARCH/$KERNELRELEASE" || \
               check_for_ib_peer_memory_symbols "$MLNX_OFED_KERNEL_DIR/$KERNELRELEASE" || \
               check_for_ib_peer_memory_symbols "$MLNX_OFED_KERNEL_DIR/default" || \
               check_for_ib_peer_memory_symbols "$VAR_DKMS_SOURCES_DIR"; then
                echo "#define NV_MLNX_IB_PEER_MEM_SYMBOLS_PRESENT" | append_conftest "symbols"
            else
                echo "#undef NV_MLNX_IB_PEER_MEM_SYMBOLS_PRESENT" | append_conftest "symbols"
            fi
        ;;

        add_memory_driver_managed)
            #
            # Determine if the add_memory_driver_managed function is present
            #
            # Added by commit 7b7b27214bba ("mm/memory_hotplug: introduce
            # add_memory_driver_managed()") in v5.8-rc1 (2020-06-05)
            #
            CODE="
            #include <linux/memory_hotplug.h>
            void conftest_add_memory_driver_managed() {
                add_memory_driver_managed();
            }"

            compile_check_conftest "$CODE" "NV_ADD_MEMORY_DRIVER_MANAGED_PRESENT" "" "functions"
        ;;

        add_memory_driver_managed_has_mhp_flags_arg)
            #
            # Check if add_memory_driver_managed() has mhp_flags arg.
            #
            # Added by commit b6117199787c ("mm/memory_hotplug: prepare passing flags to
            # add_memory() and friends") in v5.10-rc1 (2020-10-16)
            #
            CODE="
            #include <linux/memory_hotplug.h>
            int add_memory_driver_managed(int nid, u64 start, u64 size,
                                          const char *resource_name,
                                          mhp_t mhp_flags) {
                return 0;
            }"

            compile_check_conftest "$CODE" "NV_ADD_MEMORY_DRIVER_MANAGED_HAS_MHP_FLAGS_ARG" "" "types"
        ;;

        remove_memory_has_nid_arg)
            #
            # Check if remove_memory() has nid parameter.
            #
            # Removed by commit e1c158e4956612e7 ("mm/memory_hotplug: remove nid
            # parameter from remove_memory() and friends") in v5.15-rc1 (2021-09-09)
            #
            CODE="
            #include <linux/memory_hotplug.h>
            int remove_memory(int nid, u64 start, u64 size) {
                return 0;
            }"

            compile_check_conftest "$CODE" "NV_REMOVE_MEMORY_HAS_NID_ARG" "" "types"
        ;;

        offline_and_remove_memory)
            #
            # Determine if the offline_and_remove_memory function is present.
            #
            # Added by commit 08b3acd7a68fc179 ("mm/memory_hotplug: Introduce
            # offline_and_remove_memory()") in v5.8-rc1 (2020-06-05)
            #
            CODE="
            #include <linux/memory_hotplug.h>
            void conftest_offline_and_remove_memory() {
                offline_and_remove_memory();
            }"

            compile_check_conftest "$CODE" "NV_OFFLINE_AND_REMOVE_MEMORY_PRESENT" "" "functions"
        ;;

        device_property_read_u64)
            #
            # Determine if the device_property_read_u64 function is present
            #
            # Added by commit b31384fa5de37a1 ("Driver core: Unified device
            # properties interface for platform firmware") in v3.19-rc1 (2014-11-05)
            #
            CODE="
            #include <linux/acpi.h>
            void conftest_device_property_read_u64() {
                device_property_read_u64();
            }"

            compile_check_conftest "$CODE" "NV_DEVICE_PROPERTY_READ_U64_PRESENT" "" "functions"
        ;;

        of_property_count_elems_of_size)
            #
            # Determine if of_property_count_elems_of_size is present
            #
            # Added by commit 1df09bcof (" Move OF property and graph API from
            # base.c to property.c"
            #
            # Test if linux/of.h header file inclusion is successful or not,
            # depending on that check, for of_property_count_elems_of_size
            # presence
            #
            echo "$CONFTEST_PREAMBLE
            #include <linux/of.h>
            " > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                rm -f conftest$$.o
                CODE="
                #include <linux/of.h>
                void conftest_of_property_count_elems_of_size() {
                    of_property_count_elems_of_size();
                }"

                compile_check_conftest "$CODE" "NV_OF_PROPERTY_COUNT_ELEMS_OF_SIZE_PRESENT" "" "functions"
            else
                echo "#undef NV_OF_PROPERTY_COUNT_ELEMS_OF_SIZE_PRESENT" | append_conftest "functions"
            fi
        ;;

        of_property_read_variable_u8_array)
            #
            # Determine if of_property_read_variable_u8_array is present
            #
            # Added by commit 1df09bcof (" Move OF property and graph API from
            # base.c to property.c"
            #
            # Test if linux/of.h header file inclusion is successful or not,
            # depending on that, check for of_property_read_variable_u8_array
            # presence
            #
            echo "$CONFTEST_PREAMBLE
            #include <linux/of.h>
            " > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                rm -f conftest$$.o
                CODE="
                #include <linux/of.h>
                void conftest_of_property_read_variable_u8_array() {
                    of_property_read_variable_u8_array();
                }"

                compile_check_conftest "$CODE" "NV_OF_PROPERTY_READ_VARIABLE_U8_ARRAY_PRESENT" "" "functions"
            else
                echo "#undef NV_OF_PROPERTY_READ_VARIABLE_U8_ARRAY_PRESENT" | append_conftest "functions"
            fi
        ;;

        of_property_read_variable_u32_array)
            #
            # Determine if of_property_read_variable_u32_array is present
            #
            # Added by commit 1df09bcof (" Move OF property and graph API from
            # base.c to property.c"
            #
            # Test if linux/of.h header file inclusion is successful or not,
            # depending on that, check for of_property_read_variable_u32_array
            # presence
            #
            echo "$CONFTEST_PREAMBLE
            #include <linux/of.h>
            " > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                rm -f conftest$$.o
                CODE="
                #include <linux/of.h>
                void conftest_of_property_read_variable_u32_array() {
                    of_property_read_variable_u32_array();
                }"

                compile_check_conftest "$CODE" "NV_OF_PROPERTY_READ_VARIABLE_U32_ARRAY_PRESENT" "" "functions"
            else
                echo "#undef NV_OF_PROPERTY_READ_VARIABLE_U32_ARRAY_PRESENT" | append_conftest "functions"
            fi
        ;;

        devm_of_platform_populate)
            #
            # Determine if devm_of_platform_populate() function is present
            #
            # Added by commit 38b0b21of (add devm_ functions for populate and
            # depopulate")
            #
            CODE="
            #if defined(NV_LINUX_OF_PLATFORM_H_PRESENT)
            #include <linux/of_platform.h>
            #endif
            void conftest_devm_of_platform_populate(void)
            {
                devm_of_platform_populate(NULL, NULL);
            }
            "
            compile_check_conftest "$CODE" "NV_DEVM_OF_PLATFORM_POPULATE_PRESENT" "" "functions"
        ;;

        of_dma_configure)
            #
            # Determine if of_dma_configure() function is present
            #
            # Added by commit 591c1eeof ("configure the platform device
            # dma parameters")
            #
            CODE="
            #if defined(NV_LINUX_OF_DEVICE_H_PRESENT)
            #include <linux/of_device.h>
            #endif
            void conftest_of_dma_configure(void)
            {
                of_dma_configure();
            }
            "

            compile_check_conftest "$CODE" "NV_OF_DMA_CONFIGURE_PRESENT" "" "functions"
        ;;

        icc_get)
            #
            # Determine if icc_get() function is present
            #
            # Added by commit 11f1cec ("interconnect: Add generic on-chip
            # interconnect API")
            #
            CODE="
            #if defined(NV_LINUX_INTERCONNECT_H_PRESENT)
            #include <linux/interconnect.h>
            #endif
            void conftest_icc_get(void)
            {
                icc_get();
            }
            "

            compile_check_conftest "$CODE" "NV_ICC_GET_PRESENT" "" "functions"
        ;;

        devm_of_icc_get)
            #
            # Determine if devm_of_icc_get() function is present
            #
	    # Added by commit e145d9a ("interconnect: Add devm_of_icc_get() as
            # exported API for user interconnect API")
            #
            CODE="
            #if defined(NV_LINUX_INTERCONNECT_H_PRESENT)
            #include <linux/interconnect.h>
            #endif
            void conftest_devm_of_icc_get(void)
            {
                devm_of_icc_get();
            }
            "

            compile_check_conftest "$CODE" "NV_DEVM_ICC_GET_PRESENT" "" "functions"
        ;;

        icc_set_bw)
            #
            # Determine if icc_set_bw() function is present
            #
            # Added by commit 11f1cec ("interconnect: Add generic on-chip
            # interconnect API")
            #
            CODE="
            #if defined(NV_LINUX_INTERCONNECT_H_PRESENT)
            #include <linux/interconnect.h>
            #endif
            void conftest_icc_set_bw(void)
            {
                icc_set_bw();
            }
            "

            compile_check_conftest "$CODE" "NV_ICC_SET_BW_PRESENT" "" "functions"
        ;;

        icc_put)
            #
            # Determine if icc_put() function is present
            #
            # Added by commit 11f1cec ("interconnect: Add generic on-chip
            # interconnect API")
            #
            CODE="
            #if defined(NV_LINUX_INTERCONNECT_H_PRESENT)
            #include <linux/interconnect.h>
            #endif
            void conftest_icc_put(void)
            {
                icc_put();
            }
            "

            compile_check_conftest "$CODE" "NV_ICC_PUT_PRESENT" "" "functions"
        ;;

        i2c_new_client_device)
            #
            # Determine if i2c_new_client_device() function is present
            #
            # Added by commit 390fd04i2c ("remove deprecated i2c_new_device API")
            #
            CODE="
            #include <linux/i2c.h>
            void conftest_i2c_new_client_device(void)
            {
                i2c_new_client_device();
            }
            "

            compile_check_conftest "$CODE" "NV_I2C_NEW_CLIENT_DEVICE_PRESENT" "" "functions"
        ;;

        i2c_unregister_device)
            #
            # Determine if i2c_unregister_device() function is present
            #
            # Added by commit 9c1600ei2c ("Add i2c_board_info and i2c_new_device()")
            #
            CODE="
            #include <linux/i2c.h>
            void conftest_i2c_unregister_device(void)
            {
                i2c_unregister_device();
            }
            "

            compile_check_conftest "$CODE" "NV_I2C_UNREGISTER_DEVICE_PRESENT" "" "functions"
        ;;

        i2c_driver_struct_probe_without_i2c_device_id_arg)
            #
            # Determine if function probe() of struct i2c_driver has
            # struct i2c_device_id as argument or not.
            #
            # Removed by commit 03c835f498b54 ("i2c: Switch .probe() to not take an id parameter")
            # Linux 6.3
            #
            CODE="
            #define _LINUX_EFI_H
            #include <linux/i2c.h>
            void conftest_i2c_driver_struct_probe_without_i2c_device_id_arg(struct i2c_driver *i2cd) {
                i2cd->probe(NULL);
            }"

            compile_check_conftest "$CODE" "NV_I2C_DRIVER_STRUCT_PROBE_WITHOUT_I2C_DEVICE_ID_ARG" "" "types"
        ;;

        i2c_driver_struct_has_probe_new)
            #
            # Determine if struct i2c_driver has probe_new() present
            #
            # Added by commit 5eb1e6e459cf ("i2c: Drop legacy callback .probe_new()")
            #
            CODE="
            #define _LINUX_EFI_H
            #include <linux/i2c.h>
            int conftest_i2c_driver_struct_has_probe_new(void) {
                return offsetof(struct i2c_driver, probe_new);
            }"

            compile_check_conftest "$CODE" "NV_I2C_DRIVER_STRUCT_HAS_PROBE_NEW" "" "types"
        ;;

        i2c_driver_struct_remove_return_type_int)
            #
            # Determine if return type of .remove function of struct i2c_driver is int or void.
            #
            # The return type of .remove is changed with commit ed5c2f5fd10dda ("i2c: Make
            # remove callback return void") in Linux 6.1.
            #
            CODE="
            #define _LINUX_EFI_H
            #include <linux/i2c.h>
            int conftest_i2c_i2c_driver_struct_remove_return_type_int(struct i2c_driver *i2cd) {
                return i2cd->remove(NULL);
            }"

            compile_check_conftest "$CODE" "NV_I2C_DRIVER_STRUCT_REMOVE_RETURN_TYPE_INT" "" "types"
        ;;

        i2c_mux_add_adapter_has_no_class_argument)
            #
            # Determine if the i2c_mux_add_adapter() has no class argument.
            #
            # Commit fec1982d7072 ("i2c: mux: Remove class argument from i2c_mux_add_adapter()")
            # removed the 'class' argument from i2c_mux_add_adapter() in Linux v6.10.
            #
            CODE="
            #define _LINUX_EFI_H
            #include <linux/i2c-mux.h>
            int conftest_i2c_mux_add_adapter_has_no_class_argument(struct i2c_mux_core *muxc) {
                return i2c_mux_add_adapter(muxc, 0, 0);
            }"

            compile_check_conftest "$CODE" "NV_I2C_MUX_ADD_ADAPTER_HAS_NO_CLASS_ARG" "" "types"
        ;;

        of_get_named_gpio)
            #
            # Determine if of_get_named_gpio() function is present
            #
            # Added by commit a6b0919 ("of/gpio: Add new method for getting gpios
            # under different property names")
            #
            CODE="
            #if defined(NV_LINUX_OF_GPIO_H_PRESENT)
            #include <linux/of_gpio.h>
            #endif
            void conftest_of_get_named_gpio(void)
            {
                of_get_named_gpio();
            }
            "

            compile_check_conftest "$CODE" "NV_OF_GET_NAME_GPIO_PRESENT" "" "functions"
        ;;

        of_get_named_gpio_flags)
            #
            # Determine if of_get_named_gpio_flags() function is present
            #
            # This APIS is removed in commit 40fc56ee608cdb ("gpiolib:
            # of: remove of_get_gpio[_flags]() and of_get_named_gpio_flags()")
            # in Linux 6.2.
            #
            CODE="
            #include <linux/of_gpio.h>
            void conftest_of_get_named_gpio_flags(void)
            {
                of_get_named_gpio_flags();
            }
            "

            compile_check_conftest "$CODE" "NV_OF_GET_NAMED_GPIO_FLAGS_PRESENT" "" "functions"
        ;;

        gpio_chip_struct_has_of_node_present)
            #
            # Determine if struct gpio_chip has the of_node member or not.
            #
            # The of_node from struct gpio_chip is removed from commit 70d0fc4288dab
            # ("gpiolib: Get rid of not used of_node member") in Linux 6.2
            #
            CODE="
            #include <linux/gpio/driver.h>
            int conftest_gpio_chip_struct_has_of_node_present(void)
            {
                return offsetof(struct gpio_chip, of_node);
            }
            "

            compile_check_conftest "$CODE" "NV_GPIO_CHIP_STRUCT_HAS_OF_NODE_PRESENT" "" "types"
        ;;

        devm_gpio_request_one)
            #
            # Determine if devm_gpio_request_one() function is present
            #
            # Added by commit 09d71ff (gpiolib: Implement devm_gpio_request_one()")
            #
            CODE="
            #if defined(NV_LINUX_GPIO_H_PRESENT)
            #include <linux/gpio.h>
            #endif
            void conftest_devm_gpio_request_one(void)
            {
                devm_gpio_request_one();
            }
            "

            compile_check_conftest "$CODE" "NV_DEVM_GPIO_REQUEST_ONE_PRESENT" "" "functions"
        ;;

        gpio_direction_input)
            #
            # Determine if gpio_direction_input() function is present
            #
            # Added by commit c7caf86 (gpio: remove gpio_ensure_requested()")
            #
            CODE="
            #if defined(NV_LINUX_GPIO_H_PRESENT)
            #include <linux/gpio.h>
            #endif
            void conftest_gpio_direction_input(void)
            {
                gpio_direction_input();
            }
            "

            compile_check_conftest "$CODE" "NV_GPIO_DIRECTION_INPUT_PRESENT" "" "functions"
        ;;

        gpio_direction_output)
            #
            # Determine if gpio_direction_output() function is present
            #
            # Added by commit c7caf86 (gpio: remove gpio_ensure_requested()")
            #
            CODE="
            #if defined(NV_LINUX_GPIO_H_PRESENT)
            #include <linux/gpio.h>
            #endif
            void conftest_gpio_direction_output(void)
            {
                gpio_direction_output();
            }
            "

            compile_check_conftest "$CODE" "NV_GPIO_DIRECTION_OUTPUT_PRESENT" "" "functions"
        ;;

        gpio_get_value)
            #
            # Determine if gpio_get_value() function is present
            #
            # Added by commit 7563bbf ("gpiolib/arches: Centralise bolierplate
            # asm/gpio.h")
            #
            CODE="
            #if defined(NV_LINUX_GPIO_H_PRESENT)
            #include <linux/gpio.h>
            #endif
            void conftest_gpio_get_value(void)
            {
                gpio_get_value();
            }
            "

            compile_check_conftest "$CODE" "NV_GPIO_GET_VALUE_PRESENT" "" "functions"
        ;;

        gpio_set_value)
            #
            # Determine if gpio_set_value() function is present
            #
            # Added by commit 7563bbf ("gpiolib/arches: Centralise bolierplate
            # asm/gpio.h")
            #
            CODE="
            #if defined(NV_LINUX_GPIO_H_PRESENT)
            #include <linux/gpio.h>
            #endif
            void conftest_gpio_set_value(void)
            {
                gpio_set_value();
            }
            "

            compile_check_conftest "$CODE" "NV_GPIO_SET_VALUE_PRESENT" "" "functions"
        ;;

        gpio_to_irq)
            #
            # Determine if gpio_to_irq() function is present
            #
            # Added by commit 7563bbf ("gpiolib/arches: Centralise bolierplate
            # asm/gpio.h")
            #
            CODE="
            #if defined(NV_LINUX_GPIO_H_PRESENT)
            #include <linux/gpio.h>
            #endif
            void conftest_gpio_to_irq(void)
            {
                gpio_to_irq();
            }
            "

            compile_check_conftest "$CODE" "NV_GPIO_TO_IRQ_PRESENT" "" "functions"
        ;;

        migrate_vma_setup)
            #
            # Determine if migrate_vma_setup() function is present
            #
            # migrate_vma_setup() function was added by commit
            # a7d1f22bb74f32cf3cd93f52776007e161f1a738 ("mm: turn migrate_vma
            # upside down) in v5.4.
            # (2019-08-20).
            CODE="
            #include <linux/migrate.h>
            int conftest_migrate_vma_setup(void) {
                migrate_vma_setup();
            }"

            compile_check_conftest "$CODE" "NV_MIGRATE_VMA_SETUP_PRESENT" "" "functions"
        ;;

        migrate_vma_added_flags)
            #
            # Determine if migrate_vma structure has flags
            #
            # flags were added to struct migrate_vma by commit
            # 5143192cd410c4fc83be09a2e73423765aee072b ("mm/migrate: add a flags
            # parameter to_migrate_vma) in v5.9.
            # (2020-07-28).
            CODE="
            #include <linux/migrate.h>
            int conftest_migrate_vma_added_flags(void) {
                return offsetof(struct migrate_vma, flags);
            }"

            compile_check_conftest "$CODE" "NV_MIGRATE_VMA_FLAGS_PRESENT" "" "types"
        ;;

        drm_device_has_pdev)
            #
            # Determine if the 'drm_device' structure has a 'pdev' field.
            #
            # Removed by commit b347e04452ff ("drm: Remove pdev field from
            # struct drm_device") in v5.14-rc1.
            #
            CODE="
            #if defined(NV_DRM_DRMP_H_PRESENT)
            #include <drm/drmP.h>
            #endif

            #if defined(NV_DRM_DRM_DEVICE_H_PRESENT)
            #include <drm/drm_device.h>
            #endif

            int conftest_drm_device_has_pdev(void) {
                return offsetof(struct drm_device, pdev);
            }"

            compile_check_conftest "$CODE" "NV_DRM_DEVICE_HAS_PDEV" "" "types"
        ;;

        make_device_exclusive_range)
            #
            # Determine if the make_device_exclusive_range() function is present
            #
            # make_device_exclusive_range() function was added by commit
            # b756a3b5e7ead ("mm: device exclusive memory access") in v5.14
            # (2021-06-30).
            CODE="
            #include <linux/rmap.h>
            int conftest_make_device_exclusive_range(void) {
                make_device_exclusive_range();
            }"

            compile_check_conftest "$CODE" "NV_MAKE_DEVICE_EXCLUSIVE_RANGE_PRESENT" "" "functions"
        ;;

        migrate_device_range)
            #
            # Determine if the migrate_device_range() function is present
            #
            # migrate_device_range() function was added by commit
            # e778406b40dbb ("mm/migrate_device.c: add migrate_device_range()")
            # in v6.1 (2022-09-28).
            CODE="
            #include <linux/migrate.h>
            int conftest_migrate_device_range(void) {
                migrate_device_range();
            }"

            compile_check_conftest "$CODE" "NV_MIGRATE_DEVICE_RANGE_PRESENT" "" "functions"
        ;;

        ioasid_get)
            #
            # Determine if ioasid_get() function is present
            #
            # ioasid_get() function was added by commit
            # cb4789b0d19ff231ce9f73376a023341300aed96 (iommu/ioasid: Add ioasidreferences) in v5.11.
            # (2020-11-23).
            CODE="
            #if defined(NV_LINUX_IOASID_H_PRESENT)
            #include <linux/ioasid.h>
            #endif
            void conftest_ioasid_get(void) {
                ioasid_get();
            }"

            compile_check_conftest "$CODE" "NV_IOASID_GET_PRESENT" "" "functions"
        ;;

        mm_pasid_set)
            #
            # Determine if mm_pasid_set() function is present
            #
            # mm_pasid_set() function was added by commit
            # 701fac40384f07197b106136012804c3cae0b3de (iommu/sva: Assign a
            # PASID to mm on PASID allocation and free it on mm exit) in v5.18.
            # (2022-02-15).
            CODE="
            #if defined(NV_LINUX_SCHED_MM_H_PRESENT)
            #include <linux/sched/mm.h>
            #endif
            void conftest_mm_pasid_set(void) {
                mm_pasid_set();
            }"

            compile_check_conftest "$CODE" "NV_MM_PASID_SET_PRESENT" "" "functions"
        ;;

        drm_crtc_state_has_no_vblank)
            #
            # Determine if the 'drm_crtc_state' structure has 'no_vblank'.
            #
            # drm_crtc_state::no_vblank was added by commit b25c60af7a877
            # ("drm/crtc: Add a generic infrastructure to fake VBLANK events")
            # in 4.18.0-rc3 (2018-07-03).
            #
            CODE="
            #include <drm/drm_crtc.h>
            void conftest_drm_crtc_state_has_no_vblank(void) {
                struct drm_crtc_state foo;
                (void)foo.no_vblank;
            }"

            compile_check_conftest "$CODE" "NV_DRM_CRTC_STATE_HAS_NO_VBLANK" "" "types"
        ;;

        drm_mode_config_has_allow_fb_modifiers)
            #
            # Determine if the 'drm_mode_config' structure has
            # an 'allow_fb_modifiers' field.
            #
            # an 'allow_fb_modifiers' field in the 'drm_mode_config' structure,
            # is added by commit e3eb3250d84e ("drm: add support for
            # tiled/compressed/etc modifier in addfb2") in v4.1, and removed by
            # commit 3d082157a242 ("drm: remove allow_fb_modifiers") in v5.18-rc1.
            #
            # The 'struct drm_mode_config' definition, is moved to
            # drm_mode_config.h file by commit 28575f165d36 ("drm: Extract
            # drm_mode_config.[hc]") in v4.10.
            #
            CODE="$CONFTEST_PREAMBLE
            #if defined(NV_DRM_DRM_MODE_CONFIG_H_PRESENT)
            #include <drm/drm_mode_config.h>
            #else
            #include <drm/drm_crtc.h>
            #endif
            int conftest_drm_mode_config_has_allow_fb_modifiers(void) {
                return offsetof(struct drm_mode_config, allow_fb_modifiers);
            }"

            compile_check_conftest "$CODE" "NV_DRM_MODE_CONFIG_HAS_ALLOW_FB_MODIFIERS" "" "types"
        ;;

        dma_set_mask_and_coherent)
            #
            # Determine if dma_set_mask_and_coherent function is present.
            # Added by commit 4aa806b771d1 ("DMA-API: provide a helper to set both DMA
            # and coherent DMA masks") in v3.13 (2013-06-26).
            #
            CODE="
            #include <linux/dma-mapping.h>
            void conftest_dma_set_mask_and_coherent(void) {
                dma_set_mask_and_coherent();
            }"

            compile_check_conftest "$CODE" "NV_DMA_SET_MASK_AND_COHERENT_PRESENT" "" "functions"
        ;;

        drm_has_hdr_output_metadata)
            #
            # Determine if drm_mode.h has 'hdr_output_metadata' structure.
            #
            # struct hdr_output_metadata was added by commit fbb5d0353c62d
            # ("drm: Add HDR source metadata property") in 5.1.0-rc5
            # (2019-05-16)
            #
            CODE="
            #include <drm/drm_mode.h>
            void conftest_drm_has_hdr_output_metadata(void) {
                struct hdr_output_metadata foo;
                (void)foo;
            }"

            compile_check_conftest "$CODE" "NV_DRM_HAS_HDR_OUTPUT_METADATA" "" "types"
        ;;

        uts_release)
            #
            # print the kernel's UTS_RELEASE string.
            #
            echo "#include <generated/utsrelease.h>
            UTS_RELEASE" > conftest$$.c

            $CC $CFLAGS -E -P conftest$$.c
            rm -f conftest$$.c
        ;;

        platform_irq_count)
            #
            # Determine if the platform_irq_count() function is present
            #
            # platform_irq_count was added by commit
            # 4b83555d5098e73cf2c5ca7f86c17ca0ba3b968e ("driver-core: platform: Add platform_irq_count()")
            # in 4.5-rc1 (2016-01-07)
            #
            CODE="
            #include <linux/platform_device.h>
            int conftest_platform_irq_count(void) {
                return platform_irq_count();
            }"
            compile_check_conftest "$CODE" "NV_PLATFORM_IRQ_COUNT_PRESENT" "" "functions"
        ;;

        devm_clk_bulk_get_all)
            #
            # Determine if devm_clk_bulk_get_all() function is present
            #
            # Added by commit f08c2e286 ("clk: add managed version of clk_bulk_get_all")
            #
            CODE="
            #if defined(NV_LINUX_CLK_H_PRESENT)
            #include <linux/clk.h>
            #endif
            void conftest_devm_clk_bulk_get_all(void)
            {
                devm_clk_bulk_get_all();
            }
            "
            compile_check_conftest "$CODE" "NV_DEVM_CLK_BULK_GET_ALL_PRESENT" "" "functions"
        ;;

        mmget_not_zero)
            #
            # Determine if mmget_not_zero() function is present
            #
            # mmget_not_zero() function was added by commit
            # d2005e3f41d4f9299e2df6a967c8beb5086967a9 ("userfaultfd: don't pin
            # the user memory in userfaultfd_file_create()") in v4.7
            # (2016-05-20) in linux/sched.h but then moved to linux/sched/mm.h
            # by commit 68e21be2916b359fd8afb536c1911dc014cfd03e
            # ("sched/headers: Move task->mm handling methods to
            # <linux/sched/mm.h>") in v4.11 (2017-02-01).
            CODE="
            #if defined(NV_LINUX_SCHED_MM_H_PRESENT)
            #include <linux/sched/mm.h>
            #elif defined(NV_LINUX_SCHED_H_PRESENT)
            #include <linux/sched.h>
            #endif
            void conftest_mmget_not_zero(void) {
                mmget_not_zero();
            }"

            compile_check_conftest "$CODE" "NV_MMGET_NOT_ZERO_PRESENT" "" "functions"
        ;;

        mmgrab)
            #
            # Determine if mmgrab() function is present
            #
            # mmgrab() function was added by commit
            # f1f1007644ffc8051a4c11427d58b1967ae7b75a ("mm: add new
            # mmgrab() helper") in v4.11 (2017-02-01). See comment for
            # mmget_not_zero for a description of how the headers have
            # changed.
            CODE="
            #if defined(NV_LINUX_SCHED_MM_H_PRESENT)
            #include <linux/sched/mm.h>
            #elif defined(NV_LINUX_SCHED_H_PRESENT)
            #include <linux/sched.h>
            #endif
            void conftest_mmgrab(void) {
                mmgrab();
            }"

            compile_check_conftest "$CODE" "NV_MMGRAB_PRESENT" "" "functions"
        ;;

        dma_resv_add_fence)
            #
            # Determine if the dma_resv_add_fence() function is present.
            #
            # dma_resv_add_excl_fence() and dma_resv_add_shared_fence() were
            # removed and replaced with dma_resv_add_fence() by commit
            # 73511edf8b19 ("dma-buf: specify usage while adding fences to
            # dma_resv obj v7") in v5.19-rc1 (2021-11-09).
            #
            CODE="
            #if defined(NV_LINUX_DMA_RESV_H_PRESENT)
            #include <linux/dma-resv.h>
            #endif
            void conftest_dma_resv_add_fence(void) {
                dma_resv_add_fence();
            }"

            compile_check_conftest "$CODE" "NV_DMA_RESV_ADD_FENCE_PRESENT" "" "functions"
        ;;

        dma_resv_reserve_fences)
            #
            # Determine if the dma_resv_reserve_fences() function is present.
            #
            # dma_resv_reserve_shared() was removed and replaced with
            # dma_resv_reserve_fences() by commit c8d4c18bfbc4
            # ("dma-buf/drivers: make reserving a shared slot mandatory v4") in
            # v5.19-rc1 (2021-11-16).
            #
            CODE="
            #if defined(NV_LINUX_DMA_RESV_H_PRESENT)
            #include <linux/dma-resv.h>
            #endif
            void conftest_dma_resv_reserve_fences(void) {
                dma_resv_reserve_fences();
            }"

            compile_check_conftest "$CODE" "NV_DMA_RESV_RESERVE_FENCES_PRESENT" "" "functions"
        ;;

        reservation_object_reserve_shared_has_num_fences_arg)
            #
            # Determine if reservation_object_reserve_shared() has 'num_fences'
            # argument.
            #
            # reservation_object_reserve_shared() function prototype was updated
            # to take 'num_fences' argument by commit ca05359f1e64 ("dma-buf:
            # allow reserving more than one shared fence slot") in v4.21-rc1
            # (2018-12-14).
            #
            CODE="
            #include <linux/reservation.h>
            void conftest_reservation_object_reserve_shared_has_num_fences_arg(
                    struct reservation_object *obj,
                    unsigned int num_fences) {
                (void) reservation_object_reserve_shared(obj, num_fences);
            }"

            compile_check_conftest "$CODE" "NV_RESERVATION_OBJECT_RESERVE_SHARED_HAS_NUM_FENCES_ARG" "" "types"
        ;;

        get_task_ioprio)
            #
            # Determine if the __get_task_ioprio() function is present.
            #
            # __get_task_ioprio was added by commit 893e5d32d583
            # ("block: Generalize get_current_ioprio() for any task") in
            # v6.0-rc1 (2022-06-23).
            #
            CODE="
            #include <linux/ioprio.h>
            void conftest_get_task_ioprio(void) {
                __get_task_ioprio();
            }"

            compile_check_conftest "$CODE" "NV_GET_TASK_IOPRIO_PRESENT" "" "functions"
        ;;

        num_registered_fb)
            #
            # Determine if 'num_registered_fb' variable is present.
            #
            # 'num_registered_fb' was removed by commit 5727dcfd8486
            # ("fbdev: Make registered_fb[] private to fbmem.c") in
            # v6.1-rc1 (2022-07-25).
            #
            CODE="
            #include <linux/fb.h>
            int conftest_num_registered_fb(void) {
                return num_registered_fb;
            }"

            compile_check_conftest "$CODE" "NV_NUM_REGISTERED_FB_PRESENT" "" "types"
        ;;

        acpi_video_backlight_use_native)
            #
            # Determine if acpi_video_backlight_use_native() function is present
            #
            # acpi_video_backlight_use_native was added by commit 2600bfa3df99
            # (ACPI: video: Add acpi_video_backlight_use_native() helper) for
            # v6.0 (2022-08-17). Note: the include directive for <linux/types.h>
            # in this conftest is necessary in order to support kernels between
            # commit 0b9f7d93ca61 ("ACPI / i915: ignore firmware requests for
            # backlight change") for v3.16 (2014-07-07) and commit 3bd6bce369f5
            # ("ACPI / video: Port to new backlight interface selection API")
            # for v4.2 (2015-07-16). Kernels within this range use the 'bool'
            # type and the related 'false' value in <acpi/video.h> without first
            # including the definitions of that type and value.
            #
            CODE="
            #include <linux/types.h>
            #include <acpi/video.h>
            void conftest_acpi_video_backglight_use_native(void) {
                acpi_video_backlight_use_native(0);
            }"

            compile_check_conftest "$CODE" "NV_ACPI_VIDEO_BACKLIGHT_USE_NATIVE" "" "functions"
        ;;

        vm_fault_to_errno)
            #
            # Determine if the vm_fault_to_errno() function is present.
            #
            # vm_fault_to_errno() was added by commit 9a291a7c94281 (mm/hugetlb:
            # report -EHWPOISON not -EFAULT when FOLL_HWPOISON is specified) in
            # v4.12 (2017-06-02).
            #
            CODE="
            #include <linux/mm_types.h>
            void conftest_vm_fault_to_errno(void) {
                vm_fault_to_errno();
            }"

            compile_check_conftest "$CODE" "NV_VM_FAULT_TO_ERRNO_PRESENT" "" "functions"
        ;;

        handle_mm_fault_has_mm_arg)
            #
            # Determine if handle_mm_fault() has mm argument.
            #
            # mm argument was removed from handle_mm_fault() by commit
            # dcddffd41d3f1d3bdcc1dce3f1cd142779b6d4c1 (07/26/2016) ("mm: do not
            # pass mm_struct into handle_mm_fault") in v4.8.
            #
            # To test if handle_mm_fault() has mm argument, define a function
            # with the expected signature and then define the corresponding
            # function implementation with the expected signature. Successful
            # compilation indicates that handle_mm_fault has the mm argument.
            #
            CODE="
            #include <linux/mm.h>
            #include <linux/mm_types.h>

            typeof(handle_mm_fault) conftest_handle_mm_fault_has_mm_arg;
            int conftest_handle_mm_fault_has_mm_arg(struct mm_struct *mm,
                                                    struct vm_area_struct *vma,
                                                    unsigned long address,
                                                    unsigned int flags) {
                return 0;
            }"

            compile_check_conftest "$CODE" "NV_HANDLE_MM_FAULT_HAS_MM_ARG" "" "types"
        ;;

        handle_mm_fault_has_pt_regs_arg)
            #
            # Determine if handle_mm_fault() has pt_regs argument.
            #
            # pt_regs argument was added to handle_mm_fault by commit
            # bce617edecada007aee8610fbe2c14d10b8de2f6 (08/12/2020) ("mm: do
            # page fault accounting in handle_mm_fault") in v5.9.
            #
            # To test if handle_mm_fault() has pt_regs argument, define a
            # function with the expected signature and then define the
            # corresponding function implementation with the expected signature.
            # Successful compilation indicates that handle_mm_fault has the
            # pt_regs argument.
            #
            CODE="
            #include <linux/mm.h>
            #include <linux/mm_types.h>

            typeof(handle_mm_fault) conftest_handle_mm_fault_has_pt_regs_arg;
            vm_fault_t conftest_handle_mm_fault_has_pt_regs_arg(struct vm_area_struct *vma,
                                                                unsigned long address,
                                                                unsigned int flags,
                                                                struct pt_regs *regs) {
                return 0;
            }"

            compile_check_conftest "$CODE" "NV_HANDLE_MM_FAULT_HAS_PT_REGS_ARG" "" "types"
        ;;

        pci_rebar_get_possible_sizes)
            #
            # Determine if the pci_rebar_get_possible_sizes() function is present.
            #
            # Added by commit 8fbdbb66f8c10 ("PCI: Add resizable BAR infrastructure
            # ") in v5.12
            #
            CODE="
            #include <linux/pci.h>
            void conftest_pci_rebar_get_possible_sizes(void) {
                pci_rebar_get_possible_sizes();
            }"

            compile_check_conftest "$CODE" "NV_PCI_REBAR_GET_POSSIBLE_SIZES_PRESENT" "" "functions"
        ;;

        wait_for_random_bytes)
            #
            # Determine if the wait_for_random_bytes() function is present.
            #
            # Added by commit e297a783e4156 ("random: add wait_for_random_bytes
            # API") in v4.13
            #
            CODE="
            #include <linux/random.h>
            int conftest_wait_for_random_bytes(void) {
                return wait_for_random_bytes(0);
            }"

            compile_check_conftest "$CODE" "NV_WAIT_FOR_RANDOM_BYTES_PRESENT" "" "functions"
        ;;

        drm_connector_has_override_edid)
            #
            # Determine if 'struct drm_connector' has an 'override_edid' member.
            #
            # Removed by commit 90b575f52c6ab ("drm/edid: detach debugfs EDID
            # override from EDID property update") in v6.2-rc1 (2022-10-24).
            #
            CODE="
            #if defined(NV_DRM_DRM_CRTC_H_PRESENT)
            #include <drm/drm_crtc.h>
            #endif
            #if defined(NV_DRM_DRM_CONNECTOR_H_PRESENT)
            #include <drm/drm_connector.h>
            #endif
            int conftest_drm_connector_has_override_edid(void) {
                return offsetof(struct drm_connector, override_edid);
            }"

            compile_check_conftest "$CODE" "NV_DRM_CONNECTOR_HAS_OVERRIDE_EDID" "" "types"
        ;;

        iommu_sva_bind_device_has_drvdata_arg)
            #
            # Check if iommu_sva_bind_device() has drvdata parameter.
            #
            # drvdata argument was removed by commit
            # 942fd5435dccb273f90176b046ae6bbba60cfbd8 ("iommu: Remove
            # SVM_FLAG_SUPERVISOR_MODE support") in v6.2 (2022-10-31)
            #
            CODE="
            #include <linux/iommu.h>
            #include <linux/mm_types.h>
            #include <linux/device.h>
            void conftest_iommu_sva_bind_device_has_drvdata_arg(struct device *dev,
                                                                struct mm_struct *mm,
                                                                void *drvdata) {
                (void) iommu_sva_bind_device(dev, mm, drvdata);
            }"

            compile_check_conftest "$CODE" "NV_IOMMU_SVA_BIND_DEVICE_HAS_DRVDATA_ARG" "" "types"
        ;;

        vm_area_struct_has_const_vm_flags)
            #
            # Determine if the 'vm_area_struct' structure has
            # const 'vm_flags'.
            #
            # A union of '__vm_flags' and 'const vm_flags' was added 
            # by commit bc292ab00f6c ("mm: introduce vma->vm_flags
            # wrapper functions") from v6.3-rc1 (2023-02-09) in the
            # linux kernel tree.
            #
            CODE="
            #include <linux/mm_types.h>
            int conftest_vm_area_struct_has_const_vm_flags(void) {
                return offsetof(struct vm_area_struct, __vm_flags);
            }"

            compile_check_conftest "$CODE" "NV_VM_AREA_STRUCT_HAS_CONST_VM_FLAGS" "" "types"
        ;;

        drm_driver_has_dumb_destroy)
            #
            # Determine if the 'drm_driver' structure has a 'dumb_destroy'
            # function pointer.
            #
            # Removed by commit 96a7b60f6ddb2 ("drm: remove dumb_destroy
            # callback") in v6.4-rc1 (2023-01-26).
            #
            CODE="
            #if defined(NV_DRM_DRMP_H_PRESENT)
            #include <drm/drmP.h>
            #endif

            #if defined(NV_DRM_DRM_DRV_H_PRESENT)
            #include <drm/drm_drv.h>
            #endif

            int conftest_drm_driver_has_dumb_destroy(void) {
                return offsetof(struct drm_driver, dumb_destroy);
            }"

            compile_check_conftest "$CODE" "NV_DRM_DRIVER_HAS_DUMB_DESTROY" "" "types"
        ;;

        memory_failure_has_trapno_arg)
            #
            # Check if memory_failure() has trapno parameter.
            #
            # trapno argument was removed by commit
            # 83b57531c58f4173d1c0d0b2c0bc88c853c32ea5 ("mm/memory_failure:
            # Remove unused trapno from memory_failure") in v4.15.0 (2017-7-9)
            #
            CODE="
            #include <linux/mm.h>
            void conftest_memory_failure_has_trapno_arg(unsigned long pfn,
                                                        int trapno,
                                                        int flags) {
                (void) memory_failure(pfn, trapno, flags);
            }"

            compile_check_conftest "$CODE" "NV_MEMORY_FAILURE_HAS_TRAPNO_ARG" "" "types"
        ;;

        memory_failure_mf_sw_simulated_defined)
            #
            # Check if memory_failure() flag MF_SW_SIMULATED is defined.
            #
            # MF_SW_SIMULATED was added by commit
            # 67f22ba7750f940bcd7e1b12720896c505c2d63f ("mm/hwpoison:
            # fix unpoison_memory()") in v5.19.0-rc2 (2022-6-16)
            #
            CODE="
            #include <linux/mm.h>
            int conftest_memory_failure_mf_sw_simulated_defined(void) {
                return MF_SW_SIMULATED;
            }"

            compile_check_conftest "$CODE" "NV_MEMORY_FAILURE_MF_SW_SIMULATED_DEFINED" "" "types"
        ;;

        sync_file_get_fence)
            #
            # Determine if sync_file_get_fence() function is present
            #
            # sync_file_get_fence was added by commit
            # 972526a4093243fdaf77dd7c6f8b11fba5b15864 ("dma-buf/sync_file: add
            # sync_file_get_fence()") in v4.9-rc1 (2016-08-05)
            #
            CODE="
            #if defined(NV_LINUX_SYNC_FILE_H_PRESENT)
            #include <linux/sync_file.h>
            #endif
            void conftest_sync_file_get_fence(void)
            {
                sync_file_get_fence();
            }"

            compile_check_conftest "$CODE" "NV_SYNC_FILE_GET_FENCE_PRESENT" "" "functions"
        ;;

        dma_fence_set_error)
            #
            # Determine if dma_fence_set_error() function is present
            #
            # dma_fence_set_error was added by commit
            # a009e975da5c7d42a7f5eaadc54946eb5f76c9af ("dma-fence: Introduce
            # drm_fence_set_error() helper") in v4.11-rc1 (2017-01-04)
            #
            CODE="
            #if defined(NV_LINUX_DMA_FENCE_H_PRESENT)
            #include <linux/dma-fence.h>
            #endif
            void conftest_dma_fence_set_error(void)
            {
                dma_fence_set_error();
            }"

            compile_check_conftest "$CODE" "NV_DMA_FENCE_SET_ERROR_PRESENT" "" "functions"
        ;;

        fence_ops_use_64bit_seqno)
            #
            # Determine if dma_fence_ops has the use_64bit_seqno member
            #
            # 64-bit fence seqno support was actually added by commit
            # b312d8ca3a7cebe19941d969a51f2b7f899b81e2 ("dma-buf: make fence
            # sequence numbers 64 bit v2") in v5.1-rc1 (2018-11-14), but this
            # field to explicitly declare support for it didn't get added until
            # commit 5e498abf14858945f1249d9cc4ff1e8715a307e3 ("dma-buf:
            # explicitely note that dma-fence-chains use 64bit seqno") in
            # v5.2-rc1 (2019-04-15). Since it is currently trivial to work
            # around the lack of native 64-bit seqno in our driver, we'll use
            # the work-around path for kernels prior to 5.2 to avoid further
            # ifdefing of the code.
            #
            CODE="
            #if defined(NV_LINUX_DMA_FENCE_H_PRESENT)
            #include <linux/dma-fence.h>
            #endif
            int conftest_fence_ops(void)
            {
                return offsetof(struct dma_fence_ops, use_64bit_seqno);
            }"

            compile_check_conftest "$CODE" "NV_DMA_FENCE_OPS_HAS_USE_64BIT_SEQNO" "" "types"
        ;;

        drm_fbdev_generic_setup)
            #
            # Determine whether drm_fbdev_generic_setup is present.
            #
            # drm_fbdev_generic_setup was added by commit 9060d7f49376
            # ("drm/fb-helper: Finish the generic fbdev emulation") in v4.19-rc1
            # (2018-07-03)
            #
            CODE="
            #include <drm/drm_fb_helper.h>
            #if defined(NV_DRM_DRM_FBDEV_GENERIC_H_PRESENT)
            #include <drm/drm_fbdev_generic.h>
            #endif
            void conftest_drm_fbdev_generic_setup(void) {
                drm_fbdev_generic_setup();
            }"

            compile_check_conftest "$CODE" "NV_DRM_FBDEV_GENERIC_SETUP_PRESENT" "" "functions"
        ;;

        drm_aperture_remove_conflicting_pci_framebuffers)
            #
            # Determine whether drm_aperture_remove_conflicting_pci_framebuffers is present.
            #
            # drm_fbdev_generic_setup was added in commit 2916059147ea
            # ("drm/aperture: Add infrastructure for aperture ownership) in
            # v5.14-rc1 (2021-04-12)
            #
            CODE="
            #if defined(NV_DRM_DRM_APERTURE_H_PRESENT)
            #include <drm/drm_aperture.h>
            #endif
            void conftest_drm_aperture_remove_conflicting_pci_framebuffers(void) {
                drm_aperture_remove_conflicting_pci_framebuffers();
            }"

            compile_check_conftest "$CODE" "NV_DRM_APERTURE_REMOVE_CONFLICTING_PCI_FRAMEBUFFERS_PRESENT" "" "functions"
        ;;

        drm_aperture_remove_conflicting_pci_framebuffers_has_driver_arg)
            #
            # Determine whether drm_aperture_remove_conflicting_pci_framebuffers
            # takes a struct drm_driver * as its second argument.
            #
            # Prior to commit 97c9bfe3f6605d41eb8f1206e6e0f62b31ba15d6, the
            # second argument was a char * pointer to the driver's name.
            #
            # To test if drm_aperture_remove_conflicting_pci_framebuffers() has
            # a req_driver argument, define a function with the expected
            # signature and then define the corresponding function
            # implementation with the expected signature. Successful compilation
            # indicates that this function has the expected signature.
            #
            # This change occurred in commit 97c9bfe3f660 ("drm/aperture: Pass
            # DRM driver structure instead of driver name") in v5.15
            # (2021-06-29).
            #
            CODE="
            #if defined(NV_DRM_DRM_DRV_H_PRESENT)
            #include <drm/drm_drv.h>
            #endif
            #if defined(NV_DRM_DRM_APERTURE_H_PRESENT)
            #include <drm/drm_aperture.h>
            #endif
            typeof(drm_aperture_remove_conflicting_pci_framebuffers) conftest_drm_aperture_remove_conflicting_pci_framebuffers;
            int conftest_drm_aperture_remove_conflicting_pci_framebuffers(struct pci_dev *pdev,
                                                                          const struct drm_driver *req_driver)
            {
                return 0;
            }"

            compile_check_conftest "$CODE" "NV_DRM_APERTURE_REMOVE_CONFLICTING_PCI_FRAMEBUFFERS_HAS_DRIVER_ARG" "" "types"
        ;;

        crypto)
            #
            # Determine if we support various crypto functions.
            # This test is not complete and may return false positive.
            #
            CODE="
	    #include <crypto/akcipher.h>
	    #include <crypto/algapi.h>
	    #include <crypto/ecc_curve.h>
	    #include <crypto/ecdh.h>
	    #include <crypto/hash.h>
	    #include <crypto/internal/ecc.h>
	    #include <crypto/kpp.h>
	    #include <crypto/public_key.h>
	    #include <crypto/sm3.h>
	    #include <keys/asymmetric-type.h>
	    #include <linux/crypto.h>
            void conftest_crypto(void) {
                struct shash_desc sd;
                struct crypto_shash cs;
                (void)crypto_shash_tfm_digest;
            }"

            compile_check_conftest "$CODE" "NV_CRYPTO_PRESENT" "" "symbols"
        ;;

        __assign_str_has_no_src_arg)
            #
            echo "
            #define TRACE_INCLUDE_FILE conftest$$
            #define TRACE_INCLUDE_PATH ${PWD}

            #include <linux/types.h>
            #include <linux/tracepoint.h>

            TRACE_EVENT(conftest,
                TP_PROTO(const char *test),
                TP_ARGS(test),
                TP_STRUCT__entry(
                    __string(test, test)
                ),
                TP_fast_assign(
                    __assign_str(test);
                ),
                TP_printk(\"test=%s\", __get_str(test))
            );
            #include <trace/define_trace.h>" > conftest$$.h

            CODE="
            #define CREATE_TRACE_POINTS
            #include \"conftest$$.h\"
            "

            compile_check_conftest "$CODE" "NV___ASSIGN_STR_HAS_NO_SRC_ARG" "" "types"
            rm conftest$$.h
        ;;

        __alloc_disk_node_has_lkclass_arg)
            #
            # Determine if the function __alloc_disk_node() has an 'lkclass'
            # argument.
            #
            # In Linux v5.15, commit 4dcc4874deb4 ("block: cleanup the lockdep
            # handling in *alloc_disk") added the 'lkclass' argument to the
            # __alloc_disk_node() function.
            #
            CODE="
            #include <linux/blkdev.h>
            #include <linux/lockdep_types.h>
            struct gendisk *conftest___alloc_disk_node_has_lkclass_arg(
                struct request_queue *q, struct lock_class_key *lkclass) {
                    return __alloc_disk_node(q, 0, lkclass);
            }"

            compile_check_conftest "$CODE" "NV___ALLOC_DISK_NODE_HAS_LKCLASS_ARG" "" "types"
        ;;

        blk_execute_rq_has_no_gendisk_arg)
            #
            # Determine if the function blk_execute_rq() has an argument of
            # type 'gendisk'.
            #
            # In Linux v5.17, commit b84ba30b6c7a ("block: remove the gendisk
            # argument to blk_execute_rq") removed the 'gendisk' argument from
            # the blk_execute_rq().
            #
            CODE="
            #include <linux/blk-mq.h>
            void conftest_blk_execute_rq_has_no_gendisk_arg(struct request *r) {
                    blk_execute_rq(r, false);
            }"

            compile_check_conftest "$CODE" "NV_BLK_EXECUTE_RQ_HAS_NO_GENDISK_ARG" "" "types"
        ;;

        blk_mq_alloc_disk_for_queue)
            #
            # Determine if function blk_mq_alloc_disk_for_queue() is present.
            #
            # In Linux v6.0, commit 6f8191fdf41d ("block: simplify disk shutdown")
            # added the function blk_mq_alloc_disk_for_queue() and removed
            # __alloc_disk_node().
            #
            CODE="
            #include <linux/blk-mq.h>
            void conftest_blk_mq_alloc_disk_for_queue(void) {
                blk_mq_alloc_disk_for_queue();
            }"

            compile_check_conftest "$CODE" "NV_BLK_MQ_ALLOC_DISK_FOR_QUEUE_PRESENT" "" "functions"
        ;;

        blk_mq_alloc_queue)
            #
            # Determine if function blk_mq_alloc_queue() is present.
            #
            # In Linux next-20240308, commit 9ac4dd8c47d5 ("block: pass a
            # queue_limits argument to blk_mq_init_queue") renames the function
            # blk_mq_init_queue() to blk_mq_alloc_queue() and updates the
            # arguments passed.
            #
            CODE="
            #include <linux/blk-mq.h>
            void conftest_blk_mq_alloc_queue(void) {
                blk_mq_alloc_queue();
            }"

            compile_check_conftest "$CODE" "NV_BLK_MQ_ALLOC_QUEUE_PRESENT" "" "functions"
        ;;

        blk_mq_destroy_queue)
            #
            # Determine whether function blk_mq_destroy_queue() is present.
            #
            # In Linux v6.0, commit 6f8191fdf41d ("block: simplify disk shutdown")
            # renamed the function blk_cleanup_disk() to blk_mq_destroy_queue().
            #
            CODE="
            #include <linux/blk-mq.h>
            void conftest_blk_mq_destroy_queue(void) {
                blk_mq_destroy_queue();
            }"

            compile_check_conftest "$CODE" "NV_BLK_MQ_DESTROY_QUEUE_PRESENT" "" "functions"
        ;;

        blk_queue_max_hw_sectors)
            #
            # Determine whether function blk_queue_max_hw_sectors() is present.
            #
            # Commit ec84ca4025c0 ("scsi: block: Remove now unused queue limits
            # helpers") removed the function blk_queue_max_hw_sectors() in Linux
            # v6.10.
            #
            CODE="
            #include <linux/blk-mq.h>
            void conftest_blk_queue_max_hw_sectors(void) {
                blk_queue_max_hw_sectors();
            }"

            compile_check_conftest "$CODE" "NV_BLK_QUEUE_MAX_HW_SECTORS_PRESENT" "" "functions"
        ;;

        block_device_operations_open_has_gendisk_arg)
            #
            # Determine if the 'open' function pointer from the
            # 'block_device_operations' structure has 'gendisk' type argument.
            #
            # In Linux v6.5, commit d32e2bf83791 ("block: pass a gendisk to ->open")
            # updated the arguments for the open function pointer.
            #
            CODE="
            #include <linux/blkdev.h>
            int conftest_block_device_operations_open_has_gendisk_arg(
                struct block_device_operations *ops,
                struct gendisk *disk,
                fmode_t mode) {
                    return ops->open(disk, mode);
            }"

            compile_check_conftest "$CODE" \
                    "NV_BLOCK_DEVICE_OPERATIONS_OPEN_HAS_GENDISK_ARG" "" "types"
        ;;

        block_device_operations_release_has_no_mode_arg)
            #
            # Determine if the 'release' function pointer from the
            # 'block_device_operations' structure has an argument 'mode'.
            #
            # In Linux v6.5, commit ae220766d87c ("block: remove the unused mode
            # argument to ->release") updated the arguments for the 'release'
            # function pointer.
            #
            CODE="
            #include <linux/blkdev.h>
            void conftest_block_device_operations_release_has_no_mode_arg(
                struct block_device_operations *ops,
                struct gendisk *disk) {
                    ops->release(disk);
            }"

            compile_check_conftest "$CODE" \
                    "NV_BLOCK_DEVICE_OPERATIONS_RELEASE_HAS_NO_MODE_ARG" "" "types"
        ;;

        bus_type_struct_remove_has_int_return_type)
            #
            # Determine if the 'remove' callback from the 'bus_type' structure
            # has an integer return type.
            #
            # Commit fc7a6209d571 ("bus: Make remove callback return void") made
            # the 'remove' callback return void instead of an integer in Linux
            # v5.15.
            #
            CODE="
            #include <linux/device/bus.h>
            int conftest_bus_type_struct_remove_has_int_return_type(struct device *dev,
                                                                    struct bus_type *bus) {
                    return bus->remove(dev);
            }"

            compile_check_conftest "$CODE" "NV_BUS_TYPE_STRUCT_REMOVE_HAS_INT_RETURN_TYPE" "" "types"
        ;;

        bus_type_struct_uevent_has_const_dev_arg)
            #
            # Determine if the 'uevent' callback from the 'bus_type' structure
            # has a const 'struct dev' argument.
            #
            # Commit 2a81ada32f0e ("driver core: make struct bus_type.uevent()
            # take a const *") updated the arguments to the uevent callback
            # function in Linux v6.3.
            #
            CODE="
            #include <linux/device/bus.h>
            int conftest_bus_type_struct_remove_has_int_return_type(const struct device *dev,
                                                                    struct kobj_uevent_env *env,
                                                                    struct bus_type *bus) {
                    return bus->uevent(dev, env);
            }"

            compile_check_conftest "$CODE" "NV_BUS_TYPE_STRUCT_UEVENT_HAS_CONST_DEV_ARG" "" "types"
        ;;

        class_attribute_struct_has_const_struct_class_attribute)
            #
            # Determine if struct class_attribute function has const type "struct class_attribute"
            # argument or not.
            #
            # Modified the argument by change commit 75a2d4226b5371 ("driver core: class: mark
            # the struct class for sysfs callbacks as constant") for Linux 6.3
            #
            CODE="
            #include <linux/device/class.h>
            static ssize_t show_cb(struct class *class, struct class_attribute *attr, char *buf) {
                 return 0;
            }
            static struct class_attribute ca = {
                 .show = show_cb,
            };"

            compile_check_conftest "$CODE" "NV_CLASS_ATTRIBUTE_STRUCT_HAS_CONST_STRUCT_CLASS_ATTRIBUTE_ARG" "" "functions"
        ;;

        class_create_has_no_owner_arg)
            #
            # Determine if the class_create() function has the 'owner' argument.
            #
            # Commit 1aaba11da9aa ("driver core: class: remove module * from
            # class_create()") removed the owner argument for the class_create
            # function in Linux v6.4.
            #
            CODE="
            #include <linux/device.h>
            #include <linux/device/class.h>
            struct class *conftest_class_create_has_no_owner_arg(const char *name) {
                    return class_create(name);
            }"

            compile_check_conftest "$CODE" "NV_CLASS_CREATE_HAS_NO_OWNER_ARG" "" "types"
        ;;

        class_struct_devnode_has_const_dev_arg)
            #
            # Determine if the 'class' structure devnode function pointer
            # has const 'struct dev' argument.
            #
            # Commit ff62b8e6588f ("driver core: make struct class.devnode()
            # take a const *") updated the class_register function to take a
            # const class structure in Linux v6.2.
            #
            CODE="
            #include <linux/device.h>
            #include <linux/device/class.h>
            #include <linux/types.h>
            void conftest_class_struct_devnode_has_const_dev_arg(struct class *c) {
                    char *(*fn)(const struct device *dev, umode_t *mode) = c->devnode;
            }"

            compile_check_conftest "$CODE" "NV_CLASS_STRUCT_DEVNODE_HAS_CONST_DEV_ARG" "" "types"
        ;;

        define_semaphore_has_number_arg)
            #
            # Determine if the macro DEFINE_SEMAPHORE has a number argument.
            #
            # In Linux v6.4, 48380368dec1 ("Change DEFINE_SEMAPHORE() to
            # take a number argument") updated the macro DEFINE_SEMAPHORE to
            # take a number argument.
            #
            CODE="
            #include <linux/semaphore.h>

            DEFINE_SEMAPHORE(my_sem, 1);"

            compile_check_conftest "$CODE" "NV_DEFINE_SEMAPHORE_HAS_NUMBER_ARG" "" "types"
        ;;

        device_add_disk_has_int_return_type)
            #
            # Determine if the function device_add_disk() returns an integer.
            #
            # In Linux v5.15, commit 83cbce957446 ("block: add error handling
            # for device_add_disk / add_disk") updated the function
            # device_add_disk() to return an integer.
            #
            CODE="
            #include <linux/blkdev.h>
            int conftest_device_add_disk_has_int_return_type(struct device *dev,
                                                             struct gendisk *disk) {
                    return device_add_disk(dev, disk, NULL);
            }"

            compile_check_conftest "$CODE" "NV_DEVICE_ADD_DISK_HAS_INT_RETURN_TYPE" "" "types"
        ;;

        pwm_chip_struct_has_struct_device)
            #
            # Determine whether the pwm_chip structure has a 'struct device'
            # member and not a pointer to a dynamically allocated
            # 'struct device'.
            #
            # Commit 4c56b1434b81 ("pwm: Add a struct device to struct
            # pwm_chip") replaced a pointer to a dynamically allocated
            # 'struct device' with a statically allocated 'struct device'.
            # Note that this is part of a large re-work of the PWM core to
            # move the allocation of the pwm_chip structure into the PWM core.
            #
            CODE="
            #include <linux/pwm.h>
            void conftest_pwm_chip_struct_has_struct_device(struct pwm_chip *chip) {
                struct device *dev = &chip->dev;
            }"

            compile_check_conftest "$CODE" "NV_PWM_CHIP_STRUCT_HAS_STRUCT_DEVICE" "" "types"
        ;;

        devm_tegra_core_dev_init_opp_table_common)
            #
            # Determine whether devm_tegra_core_dev_init_opp_table_common is
            # present.
            #
            # devm_tegra_core_dev_init_opp_table_common was added in commit
            # 9131c6331726 ("soc/tegra: Add devm_tegra_core_dev_init_opp_table_common()")
            # in Linux v5.17.
            #
            CODE="
            #include <linux/thermal.h>
            void conftest_devm_tegra_core_dev_init_opp_table_common(void) {
                devm_tegra_core_dev_init_opp_table_common();
            }"

            compile_check_conftest "$CODE" "NV_DEVM_TEGRA_CORE_DEV_INIT_OPP_TABLE_COMMON_PRESENT" "" "functions"
        ;;

        devm_thermal_of_zone_register)
            #
            # Determine whether devm_thermal_of_zone_register is present.
            #
            # devm_thermal_of_zone_register was added in commit 3fd6d6e2b4e8
            # ("thermal/of: Rework the thermal device tree initialization") in
            # v6.1 (2022-08-17)
            #
            CODE="
            #include <linux/thermal.h>
            void conftest_devm_thermal_of_zone_register(void) {
                devm_thermal_of_zone_register();
            }"

            compile_check_conftest "$CODE" "NV_DEVM_THERMAL_OF_ZONE_REGISTER_PRESENT" "" "functions"
        ;;

        disk_check_media_change)
            #
            # Determine if the function 'disk_check_media_change' is present.
            #
            # In Linux v6.5, commit 444aa2c58cb3 ("block: pass a gendisk on
            # bdev_check_media_change") renamed the function bdev_check_media_change()
            # to disk_check_media_change() and changed the parameters.
            CODE="
            #include <linux/blkdev.h>
            void conftest_disk_check_media_change(void) {
                disk_check_media_change();
            }"

            compile_check_conftest "$CODE" "NV_DISK_CHECK_MEDIA_CHANGE_PRESENT" "" "functions"
        ;;

        dma_slave_config_struct_has_slave_id)
            #
            # Determine if 'struct dma_slave_config' has the 'slave_id' member.
            #
            # In Linux v5.17, commit 3c2196440757 ("dmaengine: remove slave_id config field")
            # removed the 'slave_id' member from the 'struct dma_slave_config'.
            #
            CODE="
            #include <linux/dma-engine.h>
            int conftest_dma_slave_config_struct_has_slave_id(void) {
                return offsetof(struct dma_slave_config, slave_id);
            }"

            compile_check_conftest "$CODE" \
                    "NV_DMA_SLAVE_CONFIG_STRUCT_HAS_SLAVE_ID" "" "types"
        ;;

        drm_aperture_remove_framebuffers)
            #
            # Determine if the function 'drm_aperture_remove_framebuffers'
            # has the 'struct drm_driver' argument.
            #
            # Conftest #1: In Linux v5.15, commit 97c9bfe3f660 ("drm/aperture:
            # Pass DRM driver structure instead of driver name") updated the
            # arguments for the function drm_aperture_remove_framebuffers to
            # pass 'struct drm_driver'.
            #
            CODE="
            #include <drm/drm_aperture.h>
            int conftest_drm_aperture_remove_framebuffers(
                    bool primary, const struct drm_driver *req_driver) {
                return drm_aperture_remove_framebuffers(primary, req_driver);
            }"

            compile_check_conftest "$CODE" "NV_DRM_APERTURE_REMOVE_FRAMEBUFFERS_HAS_DRM_DRIVER_ARG" "" "types"

            #
            # Conftest #2: In Linux v6.5, commit 62aeaeaa1b26 ("drm/aperture:
            # Remove primary argument") removed the 'primary' argument from the
            # function drm_aperture_remove_framebuffers().
            #
            CODE="
            #include <drm/drm_aperture.h>
            int conftest_drm_aperture_remove_framebuffers(
                    const struct drm_driver *req_driver) {
                return drm_aperture_remove_framebuffers(req_driver);
            }"

            compile_check_conftest "$CODE" "NV_DRM_APERTURE_REMOVE_FRAMEBUFFERS_HAS_NO_PRIMARY_ARG" "" "types"
        ;;

        drm_debugfs_remove_files_has_root_arg)
            #
            # Determine if the function drm_debugfs_remove_files() has the 'root' argument.
            #
            # Commit 8e455145d8f1 ("drm/debugfs: rework drm_debugfs_create_files
            # implementation v2") added a 'root' argument to the function
            # drm_debugfs_remove_files() in Linux v6.7.
            #
            CODE="
            #include <drm/drm_debugfs.h>
            int conftest_drm_debugfs_remove_files_has_root_arg(const struct drm_info_list *files,
                                                               int count, struct dentry *root,
                                                               struct drm_minor *minor) {
                return drm_debugfs_remove_files(files, count, root, minor);
            }"

            compile_check_conftest "$CODE" "NV_DRM_DEBUGFS_REMOVE_FILES_HAS_ROOT_ARG" "" "types"
        ;;

        drm_driver_struct_has_irq_enabled_arg)
            #
            # Determine if the 'drm_driver' structure
            # has the 'irq_enabled' argument.
            #
            # Commit c1736b9008cb ("drm: IRQ midlayer is now legacy") moved
            # the irq_enabled member of the drm_driver struct under
            # CONFIG_DRM_LEGACY in Linux v5.15.
            #
            CODE="
            #include <drm/drm_device.h>
            int conftest_drm_driver_struct_has_irq_enabled_arg(void) {
                return offsetof(struct drm_driver, irq_enabled);
            }"

            compile_check_conftest "$CODE" "NV_DRM_DRIVER_STRUCT_HAS_IRQ_ENABLED_ARG" "" "types"
        ;;

        drm_fb_helper_alloc_info)
            #
            # Determine if the function 'drm_fb_helper_alloc_info' is present.
            #
            # Commit 7fd50bc39d12 ("drm/fb-helper: Rename drm_fb_helper_alloc_fbi()
            # to use _info postfix") renamed the function drm_fb_helper_alloc_fbi to
            # drm_fb_helper_alloc_info in Linux v6.2.
            #
            CODE="
            #undef CONFIG_ACPI
            #include <drm/drm_fb_helper.h>
            void conftest_drm_fb_helper_alloc_info(void)
            {
                    drm_fb_helper_alloc_info();
            }"

            compile_check_conftest "$CODE" "NV_DRM_FB_HELPER_ALLOC_INFO_PRESENT" "" "functions"
        ;;

        drm_fb_helper_prepare_has_preferred_bpp_arg)
            #
            # Determine if the function 'drm_fb_helper_prepare' has the
            # argument 'preferred_bpp'.
            #
            # Commit 6c80a93be62d ("drm/fb-helper: Initialize fb-helper's
            # preferred BPP in prepare function") added the 'preferred_bpp'
            # argument to the function drm_fb_helper_prepare in Linux v6.3.
            #
            CODE="
            #undef CONFIG_ACPI
            #include <drm/drm_fb_helper.h>
            void conftest_drm_fb_helper_prepare(struct drm_device *dev,
                                                struct drm_fb_helper *helper,
                                                unsigned int preferred_bpp,
                                                const struct drm_fb_helper_funcs *funcs) {
                    drm_fb_helper_prepare(dev, helper, preferred_bpp, funcs);
            }"

            compile_check_conftest "$CODE" "NV_DRM_FB_HELPER_PREPARE_HAS_PREFERRED_BPP_ARG" "" "types"
        ;;

        drm_fb_helper_struct_has_info_arg)
            #
            # Determine if the 'drm_fb_helper' structure has the 'info' member.
            #
            # Commit 9877d8f6bc37 ("drm/fb_helper: Rename field fbdev to info in
            # struct drm_fb_helper") renaned the fbdev member of the
            # drm_fb_helper structure to info in Linux v6.2.
            #
            CODE="
            #undef CONFIG_ACPI
            #include <drm/drm_fb_helper.h>
            int conftest_drm_fb_helper_struct_has_info_arg(void) {
                return offsetof(struct drm_fb_helper, info);
            }"

            compile_check_conftest "$CODE" "NV_DRM_FB_HELPER_STRUCT_HAS_INFO_ARG" "" "types"
        ;;

        drm_fb_helper_unregister_info)
            #
            # Determine if function drm_fb_helper_unregister_info is present.
            #
            # Commit afb0ff78c13c ("drm/fb-helper: Rename
            # drm_fb_helper_unregister_fbi() to use _info postfix") renamed the
            # function drm_fb_helper_unregister_fbi to drm_fb_helper_unregister_info
            # in Linux v6.2.
            #
            CODE="
            #undef CONFIG_ACPI
            #include <drm/drm_fb_helper.h>
            void conftest_drm_fb_helper_unregister_info(void)
            {
                    drm_fb_helper_unregister_info();
            }
            "

            compile_check_conftest "$CODE" "NV_DRM_FB_HELPER_UNREGISTER_INFO_PRESENT" "" "functions"
        ;;

        drm_mode_config_struct_has_fb_base_arg)
            #
            # Determine if the 'drm_mode_config' structure has the 'fb_base' argument.
            #
            # Commit 7c99616e3fe7 ("drm: Remove drm_mode_config::fb_base") removed the
            # fb_base member from the drm_mode_config structure in Linux v6.2.
            #
            CODE="
            #include <drm/drm_mode_config.h>
            int conftest_drm_mode_config_struct_has_fb_base_arg(void) {
                return offsetof(struct drm_mode_config, fb_base);
            }"

            compile_check_conftest "$CODE" "NV_DRM_MODE_CONFIG_STRUCT_HAS_FB_BASE_ARG" "" "types"
        ;;

        drm_scdc_get_set_has_struct_drm_connector_arg)
            #
            # Determine if the functions drm_scdc_get_scrambling_status(),
            # drm_scdc_set_scrambling() and drm_scdc_set_high_tmds_clock_ratio()
            # have the 'struct drm_connector' argument.
            #
            # In Linux v6.4, commit 5d844091f237 ("drm/scdc-helper: Pimp SCDC debugs")
            # updated these drm_scdc_get/set functions to take an argument on type
            # 'struct drm_connector'.
            CODE="
            #if defined(NV_DRM_DISPLAY_DRM_SCDC_HELPER_H_PRESENT)
            #include <drm/display/drm_scdc_helper.h>
            #else
            #include <drm/drm_scdc_helper.h>
            #endif
            bool conftest_drm_scdc_get_set_has_struct_drm_connector_arg(struct drm_connector *c) {
                    return drm_scdc_get_scrambling_status(c);
            }"

            compile_check_conftest "$CODE" \
                    "NV_DRM_SCDC_GET_SET_HAS_STRUCT_DRM_CONNECTOR_ARG" "" "types"
        ;;

        ethtool_keee_struct_present)
            #
            # Determine if the 'struct ethtool_keee' is present.
            #
            # Commit d80a52335374 ("ethtool: replace struct ethtool_eee with a
            # new struct ethtool_keee on kernel side") replaced struct
            # ethtool_eee with ethtool_keee in Linux v6.9.
            #
            CODE="
            #include <linux/ethtool.h>
            int conftest_ethtool_keee_struct_present(struct ethtool_keee *keee) {
                return 0;
            }"

            compile_check_conftest "$CODE" "NV_ETHTOOL_KEEE_STRUCT_PRESENT" "" "types"
        ;;

        ethtool_ops_get_set_coalesce_has_coal_and_extack_args)
            #
            # Determine if the 'get_coalesce' and 'set_coalesce' ethtool_ops
            # callback functions support the 'kernel_ethtool_coalesce' and
            # 'netlink_ext_ack' arguments.
            #
            # Added by commit f3ccfda19319 ("ethtool: extend coalesce setting
            # uAPI with CQE mode") in Linux v5.15.
            #
            CODE="
            #include <linux/ethtool.h>
            #include <linux/netdevice.h>
            #include <linux/netlink.h>
            #include <uapi/linux/ethtool.h>
            void conftest_ethtool_ops_get_set_coalesce_has_coal_and_extack_args(struct ethtool_ops *ops) {
                    int (*fn)(struct net_device *,
                    struct ethtool_coalesce *,
                    struct kernel_ethtool_coalesce *,
                    struct netlink_ext_ack *) = ops->get_coalesce;
            }"

            compile_check_conftest "$CODE" "NV_ETHTOOL_OPS_GET_SET_COALESCE_HAS_COAL_AND_EXTACT_ARGS" "" "types"
        ;;

        ethtool_ops_get_set_ringparam_has_ringparam_and_extack_args)
            #
            # Determine if the 'get_ringparam' and 'set_ringparam' ethtool_ops
            # callback functions support the 'kernel_ethtool_ringparam' and
            # 'netlink_ext_ack' arguments.
            #
            # Added by commit 7462494408cd ("ethtool: extend ringparam
            # setting/getting API with rx_buf_len") in Linux v5.17.
            #
            CODE="
            #include <linux/ethtool.h>
            #include <linux/netdevice.h>
            #include <linux/netlink.h>
            #include <uapi/linux/ethtool.h>
            void conftest_ethtool_ops_get_set_ringparam_has_ringparam_and_extack_args(struct ethtool_ops *ops) {
                    void (*fn)(struct net_device *,
                    struct ethtool_ringparam *,
                    struct kernel_ethtool_ringparam *,
                    struct netlink_ext_ack *) = ops->get_ringparam;
            }"

            compile_check_conftest "$CODE" "NV_ETHTOOL_OPS_GET_SET_RINGPARAM_HAS_RINGPARAM_AND_EXTACT_ARGS" "" "types"
        ;;

        ethtool_ops_get_set_rxfh_has_rxfh_param_args)
            #
            # Determine if the 'get_rxfh' and 'set_rxfh' ethtool_ops functions
            # support the 'ethtool_rxfh_param' argument.
            #
            # Added by commit fb6e30a72539 ("net: ethtool: pass a pointer to
            # parameters to get/set_rxfh ethtool ops") in Linux v6.8.
            #
            CODE="
            #include <linux/ethtool.h>
            #include <linux/netdevice.h>
            #include <linux/netlink.h>
            #include <uapi/linux/ethtool.h>
            void conftest_ethtool_ops_get_set_rxfh_has_rxfh_param_args(struct ethtool_ops *ops) {
                    int (*fn)(struct net_device *,
                    struct ethtool_rxfh_param *rxfh) = ops->get_rxfh;
            }"

            compile_check_conftest "$CODE" \
                    "NV_ETHTOOL_OPS_GET_SET_RXFH_HAS_RXFH_PARAM_ARGS" "" "types"
        ;;

        genpd_xlate_t_has_const_of_phandle_args)
            #
            # Determine if genpd_xlate_t function pointer has a
            # 'const struct of_phandle_args' argument.
            #
            # Commit 4d0824608a63 ("pmdomain: core: constify of_phandle_args in xlate")
            # updated the typedef of genpd_xlate_t to make of_phandle_args argument const.
            #
            CODE="
            #include <linux/pm_domain.h>
            void conftest_genpd_xlate_t_has_const_of_phandle_args(struct genpd_onecell_data *gpd,
                                                                 const struct of_phandle_args *args,
                                                                 void *data)
            {
                gpd->xlate(args, data);
            }"

            compile_check_conftest "$CODE" "NV_GENDPD_XLATE_T_HAS_CONST_OF_PHANDLE_ARGS" "" "types"
        ;;

        gpio_device_find)
            #
            # Determine if function gpio_device_find() present and if it is
            # present, then determine if the function pointer passed to this
            # has a const data argument.
            #
            # The function gpio_device_find() was add by commit cfe102f63308
            # ("gpiolib: provide gpio_device_find()") in Linux v6.7 replacing
            # the legacy and broken gpiochip_find(), which has since been
            # removed.
            #
            # Commit faf6efd2e5e2 ("gpio: constify opaque pointer in
            # gpio_device_find() match function") updated the data argument in
            # the match function pointer to be const in Linux v6.9.
            #
            echo "$CONFTEST_PREAMBLE
            #include <linux/gpio/driver.h>
            void conftest_gpio_device_find(void)
            {
                gpio_device_find();
            }" > conftest$$.c

            $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
            rm -f conftest$$.c

            if [ -f conftest$$.o ]; then
                # gpio_find_device() is not present
                echo "#undef NV_GPIO_DEVICE_FIND_PRESENT" | append_conftest "functions"
                echo "#undef NV_GPIO_DEVICE_FIND_HAS_CONST_DATA_ARG" | append_conftest "types"
                rm -f conftest$$.o
            else
                # gpio_find_device() is present and now check
                # the type for the function pointer data argument
                echo "#define NV_GPIO_DEVICE_FIND_PRESENT" | append_conftest "functions"

                CODE="
                #include <linux/gpio/driver.h>
                void conftest_gpio_device_find(void *data,
                                           int (*match)(struct gpio_chip *gc,
                                           const void *data))
                {
                    gpio_device_find(data, match);
                }"

                compile_check_conftest "$CODE" "NV_GPIO_DEVICE_FIND_HAS_CONST_DATA_ARG" "" "types"
            fi
        ;;

        gpio_device_get_chip)
            #
            # Determine if function gpio_device_get_chip() is present.
            #
            # Added by commit 9b418780844c ("gpiolib: reluctantly provide
            # gpio_device_get_chip()") in Linux v6.7.
            #
            CODE="
            #include <linux/gpio/driver.h>
            void conftest_gpio_device_get_chip(void)
            {
                gpio_device_get_chip();
            }"

            compile_check_conftest "$CODE" "NV_GPIO_DEVICE_GET_CHIP_PRESENT" "" "functions"
        ;;

        netif_set_tso_max_size)
            #
            # Determine if netif_set_tso_max_size() function is present
            #
            # Added by commit 14d7b8122fd5 ("net: don't allow user space
            # to lift the device limits") in Linux v5.19.
            #
            CODE="
            #include <linux/netdevice.h>
            void conftest_netif_set_tso_max_size(void)
            {
                    netif_set_tso_max_size();
            }
            "

            compile_check_conftest "$CODE" "NV_NETIF_SET_TSO_MAX_SIZE_PRESENT" "" "functions"
        ;;

        netif_napi_add_weight)
            #
            # Determine if netif_napi_add_weight() function is present
            #
            # Added by commit 58caed3dacb4 ("netdev: reshuffle netif_napi_add()
            # APIs to allow dropping weight") in Linux v6.1.
            #
            CODE="
            #include <linux/netdevice.h>
            void conftest_netif_napi_add_weight(void)
            {
                    netif_napi_add_weight();
            }
            "
            compile_check_conftest "$CODE" "NV_NETIF_NAPI_ADD_WEIGHT_PRESENT" "" "functions"
        ;;

        iommu_map_has_gfp_arg)
            #
            # Determine if iommu_map() has 'gfp' argument.
            #
            # Commit 1369459b2e21 ("iommu: Add a gfp parameter to iommu_map()")
            # added a 'gfp' argument to the iommu_map function in Linux v6.3.
            #
            CODE="
            #include <linux/iommu.h>
            void conftest_iommu_map_has_gfp_arg(
                struct iommu_domain *domain,
                unsigned long iova,
                phys_addr_t paddr,
                size_t size,
                int prot,
                gfp_t gfp) {
                    iommu_map(domain, iova, paddr, size, prot, gfp);
            }"

            compile_check_conftest "$CODE" "NV_IOMMU_MAP_HAS_GFP_ARG" "" "types"
        ;;

        iio_dev_opaque_has_mlock)
            #
            # Determine if the 'iio_dev_opaque' structure has 'mlock' field.
            # 'mlock' field is moved from 'indio_dev' to 'iio_dev_opaque'
            # structure.
            #
            # Added in commit 16afe125b53f88b855d2713c8ba253d905dcf3cc (iio: core:
            # move 'mlock' to 'struct iio_dev_opaque') in v6.2 2022-10-12

            CODE="
            #include <linux/iio/iio.h>
            #include <linux/iio/iio-opaque.h>
            int conftest_iio_dev_opaque_has_mlock(void) {
                return offsetof(struct iio_dev_opaque, mlock);
            }"

            compile_check_conftest "$CODE" "NV_IIO_DEV_OPAQUE_HAS_LOCK" "" "types"
        ;;

        kthread_complete_and_exit)
            #
            # Determine if function kthread_complete_and_exit() is present.
            #
            # This function was added in Linux v5.17 by commit cead18552660
            # ("exit: Rename complete_and_exit to kthread_complete_and_exit").
            #
            CODE="
            #include <linux/kthread.h>
            void conftest_kthread_complete_and_exit(void)
            {
                    kthread_complete_and_exit();
            }
            "

            compile_check_conftest "$CODE" "NV_KTHREAD_COMPLETE_AND_EXIT_PRESENT" "" "functions"
        ;;

        mii_bus_struct_has_read_c45)
            #
            # Determine if the 'mii_bus' structure has 'read_c45' field.
            #
            # Added in commit 4e4aafcddbbf ("net: mdio: Add dedicated C45 API to
            # MDIO bus drivers") in Linux v6.3.
            #

            CODE="
            #include <linux/phy.h>
            int conftest_mii_bus_struct_has_read_c45(void) {
                return offsetof(struct mii_bus, read_c45);
            }"

            compile_check_conftest "$CODE" "NV_MII_BUS_STRUCT_HAS_READ_C45" "" "types"
        ;;

        mii_bus_struct_has_write_c45)
            #
            # Determine if the 'mii_bus' structure has 'write_c45' field.
            #
            # Added in commit 4e4aafcddbbf ("net: mdio: Add dedicated C45 API to
            # MDIO bus drivers") in Linux v6.3.
            #

            CODE="
            #include <linux/phy.h>
            int conftest_mii_bus_struct_has_read_c45(void) {
                return offsetof(struct mii_bus, write_c45);
            }"

            compile_check_conftest "$CODE" "NV_MII_BUS_STRUCT_HAS_WRITE_C45" "" "types"
        ;;

        pwm_chip_struct_has_base_arg)
            #
            # Determine if 'struct pwm_chip' has the 'base' field.
            #
            # Commit 54c86dd20bba ("pwm: Replace PWM chip unique base by unique ID")
            # removed the 'base' field of the 'pwm_chip' structure replacing it with
            # an 'id' field.
            #
            CODE="
            #include <sound/soc.h>
            int conftest_pwm_chip_struct_has_base_arg(void) {
                return offsetof(struct pwm_chip, base);
            }"

            compile_check_conftest "$CODE" "NV_PWM_CHIP_STRUCT_HAS_BASE_ARG" "" "types"
        ;;

        pwm_ops_struct_has_owner)
            #
            # Determine if the pwm_ops struct has an owner member.
            #
            # Added by commit 384461abcab6 ("pwm: Manage owner assignment implicitly
            # for drivers") in Linux 6.7.
            #
            CODE="
            #include <linux/pwm.h>
            int conftest_pwm_ops_struct_has_owner(void) {
                return offsetof(struct pwm_ops, owner);
            }"

            compile_check_conftest "$CODE" "NV_PWM_OPS_STRUCT_HAS_OWNER" "" "types"
        ;;

        pci_disable_pcie_error_reporting)
            #
            # Determine if the pci_disable_pcie_error_reporting() API available or not.
            #
            # API pci_disable_pcie_error_reporting() is dropped from Linux 6.5
            # with commit 69b264df8a4128 ("PCI/AER: Drop unused
            # pci_disable_pcie_error_reporting()")
            #
            CODE="
            #include <linux/aer.h>
            void conftest_pci_disable_pcie_error_reporting(void) {
                pci_disable_pcie_error_reporting();
            }"

            compile_check_conftest "$CODE" "NV_PCI_DISABLE_PCIE_ERROR_REPORTING_PRESENT" "" "functions"
        ;;

        pci_enable_pcie_error_reporting)
            #
            # Determine if the pci_enable_pcie_error_reporting() API available.
            #
            # API pci_enable_pcie_error_reporting() is dropped from Linux 6.5
            # with commit 7ec4b34be42345 ("PCI/AER: Unexport
            # pci_disable_pcie_error_reporting()")
            #
            CODE="
            #include <linux/aer.h>
            void conftest_pci_enable_pcie_error_reporting(void) {
                pci_enable_pcie_error_reporting();
            }"

            compile_check_conftest "$CODE" "NV_PCI_ENABLE_PCIE_ERROR_REPORTING_PRESENT" "" "functions"
        ;;

        pci_epf_alloc_space_has_epc_features_arg)
            #
            # Determine if the function pci_epf_alloc_space() has a
            # 'epc_features' argument.
            #
            # Commit e891becdccaa ("PCI: endpoint: Refactor
            # pci_epf_alloc_space() API") updated the pci_epf_alloc_space()
            # function to accept 'epc_features' as a parameter in Linux v6.9.
            #
            CODE="
            #include <linux/pci-epc.h>
            #include <linux/pci-epf.h>
            void conftest_pci_epf_alloc_space_has_epc_features_arg(
                    struct pci_epf *epf, size_t size, enum pci_barno bar,
                    const struct pci_epc_features *epc_features,
                    enum pci_epc_interface_type type) {
                pci_epf_alloc_space(epf, size, bar, epc_features, type);
            }"

            compile_check_conftest "$CODE" "NV_PCI_EPF_ALLOC_SPACE_HAS_EPC_FEATURES_ARG" "" "types"
        ;;

        pci_epf_driver_struct_probe_has_id_arg)
            #
            # Determine if the struct pci_epf_driver probe API has ID argument or not.
            #
            # The additional argument as ID is added in probe() of the struct pci_epf_driver
            # with change 081c715dfd5054 ("PCI: endpoint: Pass EPF device ID to the probe function")
            # in Linux 6.4.
            #
            CODE="
            #include <linux/pci-epf.h>
            void conftest_pci_epf_driver_struct_probe_has_id_arg(struct pci_epf_driver *epfd) {
                epfd->probe(NULL);
            }"

            compile_check_conftest "$CODE" "NV_PCI_EPF_DRIVER_STRUCT_PROBE_HAS_ID_ARG" "" "functions"
        ;;
        pci_epc_irq_type_enum_present)
            #
            # Determine if the pci_epc_irq_type enum present or not.
            #
            # In Linux v6.8, the enum pci_epc_irq_type is dropped from
            # commit 74955cb8ccc385 ("PCI: endpoint: Drop PCI_EPC_IRQ_XXX definitions")
            #
            CODE="
            #include <linux/pci-epc.h>
            enum pci_epc_irq_type irq_type;
            "

            compile_check_conftest "$CODE" "PCI_EPC_IRQ_TYPE_ENUM_PRESENT" "" "types"
        ;;

        pci_epc_event_ops_struct_has_core_deinit)
            #
            # Determine if the pci_epc_event_ops struct has the core_deinit function.
            #
            # Added by commit 3d99b5acdd3191c ("NVIDIA: SAUCE: PCI: endpoint: Add core_deinit()
            # callback support") from Nvidia PCI improvement.
            #
            CODE="
            #include <linux/pci-epf.h>
            int conftest_pci_epc_event_ops_struct_has_core_deinit(void) {
                return offsetof(struct pci_epc_event_ops, core_deinit);
            }"

            compile_check_conftest "$CODE" "NV_PCI_EPC_EVENT_OPS_STRUCT_HAS_CORE_DEINIT" "" "types"
        ;;

        register_shrinker_has_fmt_arg)
            #
            # Determine if the 'register_shrinker' function
            # has the 'fmt' argument.
            #
            # Commit e33c267ab70d ("mm: shrinkers: provide shrinkers with
            # names") added a 'fmt' argument to the register_shrinker()
            # function in Linux v6.0.
            #
            CODE="
            #include <linux/atomic.h>
            #include <linux/compiler_attributes.h>
            #include <linux/shrinker.h>
            int conftest_register_shrinker_has_fmt_arg(struct shrinker *s, const char *name) {
                    return register_shrinker(s, name);
            }"

            compile_check_conftest "$CODE" "NV_REGISTER_SHRINKER_HAS_FMT_ARG" "" "types"
        ;;

        request_struct_has_completion_data_arg)
            #
            # Determine if the 'struct request' has the 'completion_data' member.
            #
            # In Linux v6.5, commit dc8cbb65dc17 ("block: remove dead struc
            # request->completion_data field") removes the 'completion_data' member
            # from the 'struct request'.
            #
            CODE="
            #include <linux/blk-mq.h>
            int conftest_request_struct_has_completion_data_arg(void) {
                return offsetof(struct request, completion_data);
            }"

            compile_check_conftest "$CODE" "NV_REQUEST_STRUCT_HAS_COMPLETION_DATA_ARG" "" "types"
        ;;

        shrinker_alloc)
            #
            # Determine if the shrinker alloc present or not.
            #
            # In Linux v6.7, commit c42d50aefd17 ("mm: shrinker: add infrastructure for
            # dynamically allocating shrinker")
            #
            CODE="
            #include <linux/atomic.h>
            #include <linux/compiler_attributes.h>
            #include <linux/shrinker.h>
            void conftest_shrinker_alloc(void) {
                shrinker_alloc();
            }"

            compile_check_conftest "$CODE" "NV_SHRINKER_ALLOC_PRESENT" "" "functions"
        ;;

        slab_mem_spread)
            #
            # Determine if SLAB_MEM_SPREAD is defined.
            #
            # Commit f88c3fb81c4b ("mm, slab: remove last vestiges of
            # SLAB_MEM_SPREAD") removed the definition SLAB_MEM_SPREAD in
            # Linux v6.9. This definition is no longer supported and can
            # be removed for v6.9+ kernels.
            CODE="
            #include <linux/slab.h>
            void conftest_slab_mem_spread(void) {
                slab_flags_t flags = SLAB_MEM_SPREAD;
            }"

            compile_check_conftest "$CODE" "NV_SLAB_MEM_SPREAD" "" "types"
        ;;

        snd_soc_card_jack_new_has_no_snd_soc_jack_pins)
            #
            # Determine if the function snd_soc_card_jack_new() has 'pins' and
            # 'num_pins' arguments.
            #
            # In Linux v5,19, commit 19aed2d6cdb7 ("ASoC: soc-card: Create jack
            # kcontrol without pins") removed the 'pins' and 'num_pins'
            # arguments from the snd_soc_card_jack_new() function.
            #
            CODE="
            #include <sound/jack.h>
            #include <sound/soc.h>
            int conftest_snd_soc_card_jack_new_has_no_snd_soc_jack_pins(struct snd_soc_card *card,
                                                                        struct snd_soc_jack *jack) {
                return snd_soc_card_jack_new(card, \"Jack\", SND_JACK_HEADSET, jack);
            }"

            compile_check_conftest "$CODE" \
                    "NV_SND_SOC_CARD_JACK_NEW_HAS_NO_SND_SOC_JACK_PINS" "" "types"
        ;;

        snd_soc_component_driver_struct_has_non_legacy_dai_naming)
            #
            # Determine if 'struct snd_soc_component_driver' has the
            # 'non_legacy_dai_naming' member.
            #
            # In Linux v6.0, commit 01936221278c ("ASoC: soc-component: Remove
            # non_legacy_dai_naming flag") removed the 'non_legacy_dai_naming'
            # flag from the 'struct snd_soc_component_driver'.
            #
            CODE="
            #include <sound/soc-component.h>
            unsigned int conftest_snd_soc_component_driver_struct_has_non_legacy_dai_naming(
                struct snd_soc_component_driver *driver) {
                    return driver->non_legacy_dai_naming;
            }"

            compile_check_conftest "$CODE" \
                    "NV_SND_SOC_COMPONENT_DRIVER_STRUCT_HAS_NON_LEGACY_DAI_NAMING" "" "types"
        ;;

        snd_soc_dai_link_struct_has_c2c_params_arg)
            #
            # Determine if 'struct snd_soc_dai_link' has the 'c2c_params' member.
            #
            # In Linux v6.4, commits 7ddc7f91beb2 ("ASoC: soc.h: clarify Codec2Codec params")
            # and 1ea63f29c277 ("ASoC: soc.h: remove unused params/num_params") replaced the
            # 'params' member of the snd_soc_dai_link with the 'c2c_params' member.
            #
            CODE="
            #include <sound/soc.h>
            int conftest_snd_soc_dai_link_struct_has_c2c_params_args(void) {
                return offsetof(struct snd_soc_dai_link, c2c_params);
            }"

            compile_check_conftest "$CODE" \
                    "NV_SND_SOC_DAI_LINK_STRUCT_HAS_C2C_PARAMS_ARG" "" "types"
        ;;

        snd_soc_dai_ops_struct_has_probe)
            #
            # Determine if 'struct snd_soc_dai_ops' has the 'probe' member.
            #
            # In Linux v6.5, commits 516ee7009ff20 ("ASoC: tegra: merge DAI
            # call back functions into ops") added probe() callback into the
            # struct snd_soc_dai_ops.
            #
            CODE="
            #include <sound/soc.h>
            int conftest_snd_soc_dai_ops_struct_has_probe(void) {
                return offsetof(struct snd_soc_dai_ops, probe);
            }"

            compile_check_conftest "$CODE" "NV_SND_SOC_DAI_OPS_STRUCT_HAS_PROBE_PRESENT" "" "types"
        ;;

        snd_soc_of_get_dai_name_has_index_arg)
            #
            # Determine if the function 'snd_soc_of_get_dai_name()' has an index argument.
            #
            # In Linux v6.5, commit 3c8b5861850c ("ASoC: soc-core.c: add index on
            # snd_soc_of_get_dai_name()") updated the arguments to the function
            # snd_soc_of_get_dai_name().
            #
            CODE="
            #include <sound/soc.h>
            int conftest_snd_soc_of_get_dai_name_has_index_args(struct device_node *np,
                                                                const char **name) {
                    return snd_soc_of_get_dai_name(np, name, 0);
            }"

            compile_check_conftest "$CODE" "NV_SND_SOC_OF_GET_DAI_NAME_HAS_INDEX_ARG" "" "types"
        ;;

        snd_soc_rtd_to_codec)
            #
            # Determine if the snd_soc_rtd_to_codec() present or not
            #
            # In Linux v6.7, commit 1d5a2b5dd0a8d2 ("ASoC: soc.h: convert asoc_xxx()
            # to snd_soc_xxx()") to replace all asoc_xxx() to snd_soc_xxx().
            #
            CODE="
            #include <sound/soc.h>
            void conftest_snd_soc_rtd_to_codec(void) {
                snd_soc_rtd_to_codec();
            }"

            compile_check_conftest "$CODE" "NV_SND_SOC_RTD_TO_CODEC_PRESENT" "" "functions"
        ;;

        simple_util_dai_init)
            #
            # Determine if the simple_util_dai_init() is present. This will help on finding
            # if asoc_simple_xxx() renamed to simple_util_xxx()
            #
            # In Linux v6.7, commit b5a95c5bf6d69 ("ASoC: simple_card_utils.h: convert
            # not to use asoc_xxx()") add new APIs to convert asoc_simple_xxx() to
            # simple_util_xxx().
            #
            CODE="
            #include <sound/soc.h>
            #include <sound/simple_card_utils.h>
            void conftest_simple_util_dai_init(void) {
                simple_util_dai_init();
            }"

            compile_check_conftest "$CODE" "NV_ASOC_SIMPLE_RENAMED_SIMPLE" "" "functions"
        ;;

        spi_get_chipselect)
            #
            # Determine if the function 'spi_get_chip_select()' is present.
            #
            # In Linux v6.3, commit 303feb3cc06a ("spi: Add APIs in spi core to set/get
            # spi->chip_select and spi->cs_gpiod") added a helper function,
            # spi_get_chipselect(), so drivers did not need to access the
            # 'spi_device->chip_select' directly. This Linux v6.8, commit 4d8ff6b0991d
            # ("spi: Add multi-cs memories support in SPI core") updated the
            # 'spi_device->chip_select' to be an array and so using spi_get_chipselect
            # to retrieve the chipselect is required for Linux v6.8.
            #
            CODE="
            #undef CONFIG_ACPI
            #include <linux/spi/spi.h>
            void conftest_spi_get_chipselect(void) {
                spi_get_chipselect();
            }"

            compile_check_conftest "$CODE" "NV_SPI_GET_CHIPSELECT_PRESENT" "" "functions"
        ;;

        tc_taprio_qopt_offload_struct_has_cmd)
            #
            # Determine if struct tc_taprio_qopt_offload has a member named cmd
            #
            # Commit 2d800bc500fb ("net/sched: taprio: replace tc_taprio_qopt_offload
            # :: enable with a "cmd" enum") replace tc_taprio_qopt_offload structure member
            # 'enable' with 'cmd' in Linux v6.4.5.
            #
            CODE="
            #include <net/pkt_sched.h>
            int conftest_tc_taprio_qopt_offload_struct_has_cmd(void) {
                return offsetof(struct tc_taprio_qopt_offload, cmd);
            }
            "
            compile_check_conftest "$CODE" "NV_TC_TAPRIO_QOPT_OFFLOAD_STRUCT_HAS_CMD" "" "types"
        ;;

        tegra264_chip_id)
            #
            # Determine if the 'TEGRA264' definition is present.
            #
            # Added by commit d94436465152 ("soc/tegra: fuse: Add support for
            # Tegra264") in Linux v6.5.
            #
            CODE="
            #include <soc/tegra/fuse.h>
            u8 conftest_tegra264_chip_id(void) {
                    return TEGRA264;
            }"

            compile_check_conftest "$CODE" "NV_TEGRA264_CHIP_ID_PRESENT" "" "types"
        ;;

        tegra_ivc_struct_has_iosys_map)
            #
            # Determine if the 'tegra_ivc' structure has the 'map' argument.
            #
            # Commit 4c1e0a97351a ("firmware: tegra: bpmp: Use iosys-map
            # helpers") update the Tegra IVC driver to use iosys-map in Linux v6.2.
            #
            CODE="
            #if defined(NV_LINUX_IOSYS_MAP_H_PRESENT)
            #include <linux/iosys-map.h>
            #endif
            #include <soc/tegra/ivc.h>
            struct iosys_map *conftest_tegra_ivc_struct_has_iosys_map(struct tegra_ivc *ivc) {
                    return &ivc->rx.map;
            }"

            compile_check_conftest "$CODE" "NV_TEGRA_IVC_STRUCT_HAS_IOSYS_MAP" "" "types"
        ;;

        thermal_zone_device_priv)
            #
            # Determine if the function thermal_zone_device_priv() is present.
            #
            # Commit a6ff3c002146 ("thermal/core: Add a thermal zone 'devdata'
            # accessor") added function thermal_zone_device_priv() in Linux
            # v6.4.
            #
            CODE="
            #include <linux/thermal.h>
            void conftest_thermal_zone_device_priv(void) {
                thermal_zone_device_priv();
            }"

            compile_check_conftest "$CODE" "NV_THERMAL_ZONE_DEVICE_PRIV_PRESENT" "" "functions"
        ;;

        tegra_dev_iommu_get_stream_id)
            #
            # Determine if the function tegra_dev_iommu_get_stream_id is present.
            #
            # tegra_dev_iommu_get_stream_id was added in commit 493c9b68d1d8
            # ("iommu/tegra: Add tegra_dev_iommu_get_stream_id() helper") in
            # v6.2 (2022-12-07)
            #
            CODE="
            #include <linux/iommu.h>
            bool conftest_tegra_dev_iommu_get_stream_id(void) {
                return tegra_dev_iommu_get_stream_id();
            }"

            compile_check_conftest "$CODE" "NV_TEGRA_DEV_IOMMU_GET_STREAM_ID_PRESENT" "" "functions"
        ;;

        tty_operations_struct_send_xchar_has_u8_arg)
            #
            # Determine if the struct tty_operations::send_xchar argument is of type u8.
            #
            # Commit 3a00da027946 ("tty: make tty_operations::send_xchar accept u8 char")
            # updated the argument for tty_operations::send_xchar from char to u8 in Linux
            # v6.8.
            #
            CODE="
            #include <linux/tty.h>
            #include <linux/tty_driver.h>
            static inline void conftest_send_xchar(struct tty_struct *ttys, u8 ch) {}
            static struct tty_operations tty_ops = {
                  .send_xchar = conftest_send_xchar,
            };"

            compile_check_conftest "$CODE" "NV_TTY_OPERATIONS_STRUCT_SEND_XCHAR_HAS_U8_ARG" "" "types"
        ;;

        tty_operations_struct_write_has_u8_ptr_arg)
            #
            # Determine if the function write() of tty_operations has u8 type pointer argument.
            #
            # The data type of function write() of struct tty_operation has changed
            # to u8 data type from Linux 6.5 with change
            # commit 69851e4ab8feeb3 ("tty: propagate u8 data to tty_operations::write()")
            #
            CODE="
            #include <linux/tty.h>
            #include <linux/tty_driver.h>
            static inline int ser_write(struct tty_struct *ttys, const unsigned char *buf, int l) {
                 return l;
            }
            static struct tty_operations tty_ops = {
                  .write = ser_write,
            };"

            compile_check_conftest "$CODE" "NV_TTY_OPERATIONS_STRUCT_WRITE_HAS_U8_PTR_ARG" "" "functions"
        ;;

        tty_operations_struct_set_termios_has_const_ktermios_arg)
            #
            # Determine if the function set_termios of tty_operations struct has the const type argument or not.
            #
            # The callback function of tty_operations has the const type argument from the commit bec5b814d46c
            # ("serial: Make ->set_termios() old ktermios const") in Linux 6.1.
            #
            CODE="
            #include <linux/tty.h>
            #include <linux/tty_driver.h>
            static inline void test_set_termios(struct tty_struct *tty, const struct ktermios *old) {
            }
            static struct tty_operations tty_ops = {
                  .set_termios = test_set_termios,
            };"

            compile_check_conftest "$CODE" "NV_TTY_OPERATIONS_STRUCT_SET_TERMIOS_HAS_CONST_KTERMIOS_ARG" "" "types"
        ;;

        ufs_hba_variant_ops_suspend_has_status_arg)
            #
            # Determine if the 'suspend' function for the
            # 'struct ufs_hba_variant_ops' has a 'status' argument.
            #
            # In Linux v5.16, commit 9561f58442e4 ("scsi: ufs:
            # mediatek: Support vops pre suspend to disable auto-hibern8")
            # updated the arguments to the 'suspend' function of the
            # 'struct ufs_hba_variant_ops'.
            #
            CODE="
            #if defined(NV_UFS_UFSHCD_H_PRESENT)
            #include <ufs/ufshcd.h>
            #else
            #include \"../drivers/scsi/ufs/ufshcd.h\"
            #endif
            void conftest_ufs_hba_variant_ops_suspend_has_status_arg(
                struct ufs_hba_variant_ops *ops) {
                    int (*fn)(struct ufs_hba *, enum ufs_pm_op,
                    enum ufs_notify_change_status) = ops->suspend;
            }"

            compile_check_conftest "$CODE" "NV_UFS_HBA_VARIANT_OPS_SUSPEND_HAS_STATUS_ARG" "" "types"
        ;;

        ufshcd_quirks_enum_has_ufshcd_quirk_broken_64bit_address)
            #
            # Determine if the 'UFSHCD_QUIRK_BROKEN_64BIT_ADDRESS' is defined in the
            # enum ufshcd_quirks.
            #
            # In Linux v6.0, the enum UFSHCD_QUIRK_BROKEN_64BIT_ADDRESS is added as
            # commit 6554400d6f66 ("scsi: ufs: core: Add UFSHCD_QUIRK_BROKEN_64BIT_ADDRESS")
            #
            CODE="
            #include <ufs/ufshcd.h>
            enum ufshcd_quirks quirk = UFSHCD_QUIRK_BROKEN_64BIT_ADDRESS;
            "

            compile_check_conftest "$CODE" "NV_UFSHCD_QUIRKS_ENUM_HAS_UFSHCD_QUIRK_BROKEN_64BIT_ADDRESS" "" "types"
        ;;

        v4l2_async_connection_struct_present)
            #
            # Determine if the 'struct v4l2_async_connection' present or not.
            #
            # The struct v4l2_async_subdev is renamed to v4l2_async_connection with change
            # commit adb2dcd5f2d49d3 ("media: v4l: async: Rename v4l2_async_subdev
            # as v4l2_async_connection") in Linux 6.5
            #
            CODE="
            #include <media/v4l2-async.h>
            int conftest_v4l2_async_connection_struct_present(void) {
                return offsetof(struct v4l2_async_connection, match);
            }"

            compile_check_conftest "$CODE" "NV_V4L2_ASYNC_CONNECTION_STRUCT_PRESENT" "" "types"
        ;;

        v4l2_async_match_type_enum_present)
            #
            # Determine if the 'enum v4l2_async_match_type' has the "TYPE" in its name.
            #
            # In Linux 6.5, with change commit 7a2259fc5182b ("media: v4l: async:
            # Rename V4L2_ASYNC_MATCH_ macros, add TYPE_"), the enum names has "TYPE" also.
            #
            CODE="
            #include <media/v4l2-async.h>
            int conftest_v4l2_async_match_type_enum_present(void) {
                return V4L2_ASYNC_MATCH_TYPE_I2C;
            }"

            compile_check_conftest "$CODE" "NV_V4L2_ASYNC_MATCH_TYPE_ENUM_PRESENT" "" "types"
        ;;

        v4l2_async_subdev_nf_init)
            #
            # Determine if the function v4l2_async_subdev_nf_init() present or not.
            #
            # In Linux 6.5, with change commit bda8953e8c3e7e ("media: v4l: async:
            # Drop v4l2_async_nf_parse_fwnode_endpoints()"), added the function
            # v4l2_async_subdev_nf_init() and dropped v4l2_async_nf_init().
            #
            CODE="
            #include <media/v4l2-async.h>
            void conftest_v4l2_async_subdev_nf_init(void) {
                v4l2_async_subdev_nf_init();
            }"

            compile_check_conftest "$CODE" "NV_V4L2_ASYNC_SUBDEV_NF_INIT_PRESENT" "" "functions"
        ;;

        v4l2_async_notifier_init)
            #
            # Determine if the function v4l2_async_notifier_init() present or not.
            #
            # The API is renamed with  commit 3c8c15391481 ("media: v4l: async:
            # Rename async nf functions, clean up long lines") in Linux 5.16
            #
            CODE="
            #include <media/v4l2-async.h>
            void conftest_v4l2_async_notifier_init(void) {
                v4l2_async_notifier_init();
            }"

            compile_check_conftest "$CODE" "NV_V4L2_ASYNC_NOTIFIER_INIT_PRESENT" "" "functions"
        ;;

        v4l2_async_nf_init_has_v4l2_dev_arg)
            #
            # Determine if the function v4l2_async_nf_init() has v4l2_dev argument or not.
            #
            # The device argument is added in the API v4l2_async_nf_init() with commit
            # b8ec754ae4c5 ("media: v4l: async: Set v4l2_device and subdev in async notifier init")
            # in Linux 6.6.
            #
            CODE="
            #include <media/v4l2-async.h>
            void conftest_v4l2_async_nf_init_has_v4l2_dev_arg(void) {
                v4l2_async_nf_init(NULL, NULL);
            }"

            compile_check_conftest "$CODE" "NV_V4L2_ASYNC_NF_INIT_HAS_V4L2_DEV_ARG" "" "types"
        ;;

        __v4l2_async_nf_add_subdev)
            #
            # Determine if the function __v4l2_async_nf_add_subdev() present or not.
            #
            # The API is removed with commit bda8953e8c3e ("media: v4l: async: Drop
            # v4l2_async_nf_parse_fwnode_endpoints()") in Linux 6.6
            #
            CODE="
            #include <media/v4l2-async.h>
            void conftest_v4l2_async_nf_add_subdev_present(void) {
                __v4l2_async_nf_add_subdev();
            }"

            compile_check_conftest "$CODE" "NV_V4L2_ASYNC_NF_ADD_SUBDEV_PRESENT" "" "functions"
        ;;

        v4l2_subdev_pad_ops_struct_has_get_frame_interval)
            #
            # Determine if struct v4l2_subdev_pad_ops has the 'get_frame_interval'
            # function pointer.
            #
            # Added by commit 287fe160834a ("media: v4l2-subdev: Turn
            # .[gs]_frame_interval into pad operations") in Linux v6.8.
            #
            CODE="
            #define _LINUX_EFI_H
            #include <media/v4l2-subdev.h>
            int conftest_v4l2_subdev_pad_ops_struct_has_get_set_frame_interval(void) {
                return offsetof(struct v4l2_subdev_pad_ops, get_frame_interval);
            }
            "
            compile_check_conftest "$CODE" \
                    "NV_V4L2_SUBDEV_PAD_OPS_STRUCT_HAS_GET_FRAME_INTERVAL" "" "types"
        ;;

        v4l2_subdev_pad_ops_struct_has_dv_timings)
            #
            # Determine if struct v4l2_subdev_pad_ops has the 'g_dv_timings'
            # and 's_dv_timings' function pointers.
            #
            # Commit 009e12561369 ("media: v4l2-subdev: Add pad versions of dv
            # timing subdev calls)" added 'g_dv_timings' and 's_dv_timnigs' to
            # the v4l2_subdev_pad_ops structure. Commit d8c9a6e204f1 ("media:
            # v4l2-subdev: Remove non-pad dv timing callbacks") then removed the
            # the original 'g_dv_timings' and 's_dv_timings' from the
            # v4l2_subdev_video_ops structure. These changes were made for Linux
            # v6.10.
            CODE="
            #define _LINUX_EFI_H
            #include <media/v4l2-subdev.h>
            int conftest_v4l2_subdev_pad_ops_struct_has_dv_timings(void) {
                return offsetof(struct v4l2_subdev_pad_ops, g_dv_timings);
            }
            "
            compile_check_conftest "$CODE" \
                    "NV_V4L2_SUBDEV_PAD_OPS_STRUCT_HAS_DV_TIMINGS" "" "types"
        ;;
        crypto_engine_ctx_struct_removed_test)
            #
            # Determine if struct 'crypto_engine_ctx' is removed in linux kernel.
            #
            # Commit 5ce0bc68e0ee ("crypto: engine - Remove crypto_engine_ctx")
            # Linux v6.6 removed struct crypto_engine_ctx
            #
            CODE="
            #include <crypto/engine.h>
            void conftest_crypto_engine_ctx_struct_removed_test(void) {
                    struct crypto_engine_ctx *ptr = NULL;
                    struct crypto_engine_ctx enginectx;
                    ptr = &enginectx;
            }"

            compile_check_conftest "$CODE" "NV_CONFTEST_REMOVE_STRUCT_CRYPTO_ENGINE_CTX" "" "functions"
        ;;

        # When adding a new conftest entry, please use the correct format for
        # specifying the relevant upstream Linux kernel commit.
        #
        # <function> was added|removed|etc by commit <sha> ("<commit message")
        # in <kernel-version> (<commit date>).

        *)
            # Unknown test name given
            echo "Error: unknown conftest '$1' requested" >&2
            exit 1
        ;;
    esac
}

case "$5" in
    cc_sanity_check)
        #
        # Check if the selected compiler can create object files
        # in the current environment.
        #
        VERBOSE=$6

        echo "int cc_sanity_check(void) {
            return 0;
        }" > conftest$$.c

        $CC -c conftest$$.c > /dev/null 2>&1
        rm -f conftest$$.c

        if [ ! -f conftest$$.o ]; then
            if [ "$VERBOSE" = "full_output" ]; then
                echo "";
            fi
            if [ "$CC" != "cc" ]; then
                echo "The C compiler '$CC' does not appear to be able to"
                echo "create object files.  Please make sure you have "
                echo "your Linux distribution's libc development package"
                echo "installed and that '$CC' is a valid C compiler";
                echo "name."
            else
                echo "The C compiler '$CC' does not appear to be able to"
                echo "create executables.  Please make sure you have "
                echo "your Linux distribution's gcc and libc development"
                echo "packages installed."
            fi
            if [ "$VERBOSE" = "full_output" ]; then
                echo "";
                echo "*** Failed CC sanity check. Bailing out! ***";
                echo "";
            fi
            exit 1
        else
            rm -f conftest$$.o
            exit 0
        fi
    ;;

    cc_version_check)
        #
        # Verify that the same compiler major and minor version is
        # used for the kernel and kernel module. A mismatch condition is
        # not considered fatal, so this conftest returns a success status
        # code, even if it fails. Failure of the test can be distinguished
        # by testing for empty (success) versus non-empty (failure) output.
        #
        # Some gcc version strings that have proven problematic for parsing
        # in the past:
        #
        #  gcc.real (GCC) 3.3 (Debian)
        #  gcc-Version 3.3 (Debian)
        #  gcc (GCC) 3.1.1 20020606 (Debian prerelease)
        #  version gcc 3.2.3
        #
        #  As of this writing, GCC uses a version number as x.y.z and below
        #  are the typical version strings seen with various distributions.
        #  gcc (GCC) 4.4.7 20120313 (Red Hat 4.4.7-23)
        #  gcc version 4.8.5 20150623 (Red Hat 4.8.5-39) (GCC)
        #  gcc (GCC) 8.3.1 20190507 (Red Hat 8.3.1-4)
        #  gcc (GCC) 10.2.1 20200723 (Red Hat 10.2.1-1)
        #  gcc (Ubuntu 9.3.0-17ubuntu1~20.04) 9.3.0
        #  gcc (Ubuntu 7.5.0-3ubuntu1~16.04) 7.5.0
        #  gcc (Debian 8.3.0-6) 8.3.0
        #  aarch64-linux-gcc.br_real (Buildroot 2020.08-14-ge5a2a90) 9.3.0, GNU ld (GNU Binutils) 2.33.1
        #
        #  In order to extract GCC version correctly for version strings
        #  like the last one above, we first check for x.y.z and if that
        #  fails, we fallback to x.y format.
        VERBOSE=$6

        kernel_compile_h=$OUTPUT/include/generated/compile.h

        if [ ! -f ${kernel_compile_h} ]; then
            # The kernel's compile.h file is not present, so there
            # isn't a convenient way to identify the compiler version
            # used to build the kernel.
            IGNORE_CC_MISMATCH=1
        fi

        if [ -n "$IGNORE_CC_MISMATCH" ]; then
            exit 0
        fi

        kernel_cc_string=`cat ${kernel_compile_h} | \
            grep LINUX_COMPILER | cut -f 2 -d '"'`

        kernel_cc_version=`echo ${kernel_cc_string} | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -n 1`
        if [ -z "${kernel_cc_version}" ]; then
            kernel_cc_version=`echo ${kernel_cc_string} | grep -o '[0-9]\+\.[0-9]\+' | head -n 1`
        fi
        kernel_cc_major=`echo ${kernel_cc_version} | cut -d '.' -f 1`
        kernel_cc_minor=`echo ${kernel_cc_version} | cut -d '.' -f 2`

        echo "
        #if (__GNUC__ != ${kernel_cc_major}) || (__GNUC_MINOR__ != ${kernel_cc_minor})
        #error \"cc version mismatch\"
        #endif
        " > conftest$$.c

        $CC $CFLAGS -c conftest$$.c > /dev/null 2>&1
        rm -f conftest$$.c

        if [ -f conftest$$.o ]; then
            rm -f conftest$$.o
            exit 0;
        else
            #
            # The gcc version check failed
            #

            if [ "$VERBOSE" = "full_output" ]; then
                echo "";
                echo "Warning: Compiler version check failed:";
                echo "";
                echo "The major and minor number of the compiler used to";
                echo "compile the kernel:";
                echo "";
                echo "${kernel_cc_string}";
                echo "";
                echo "does not match the compiler used here:";
                echo "";
                $CC --version
                echo "";
                echo "It is recommended to set the CC environment variable";
                echo "to the compiler that was used to compile the kernel.";
                echo ""
                echo "To skip the test and silence this warning message, set";
                echo "the IGNORE_CC_MISMATCH environment variable to \"1\".";
                echo "However, mixing compiler versions between the kernel";
                echo "and kernel modules can result in subtle bugs that are";
                echo "difficult to diagnose.";
                echo "";
                echo "*** Failed CC version check. ***";
                echo "";
            elif [ "$VERBOSE" = "just_msg" ]; then
                echo "Warning: The kernel was built with ${kernel_cc_string}, but the" \
                     "current compiler version is `$CC --version | head -n 1`.";
            fi
            exit 0;
        fi
    ;;

    xen_sanity_check)
        #
        # Check if the target kernel is a Xen kernel. If so, exit, since
        # the RM doesn't currently support Xen.
        #
        VERBOSE=$6

        if [ -n "$IGNORE_XEN_PRESENCE" -o -n "$VGX_BUILD" ]; then
            exit 0
        fi

        test_xen

        if [ "$XEN_PRESENT" != "0" ]; then
            echo "The kernel you are installing for is a Xen kernel!";
            echo "";
            echo "The NVIDIA driver does not currently support Xen kernels. If ";
            echo "you are using a stock distribution kernel, please install ";
            echo "a variant of this kernel without Xen support; if this is a ";
            echo "custom kernel, please install a standard Linux kernel.  Then ";
            echo "try installing the NVIDIA kernel module again.";
            echo "";
            if [ "$VERBOSE" = "full_output" ]; then
                echo "*** Failed Xen sanity check. Bailing out! ***";
                echo "";
            fi
            exit 1
        else
            exit 0
        fi
    ;;

    preempt_rt_sanity_check)
        #
        # Check if the target kernel has the PREEMPT_RT patch set applied. If
        # so, exit, since the RM doesn't support this configuration.
        #
        VERBOSE=$6

        if [ -n "$IGNORE_PREEMPT_RT_PRESENCE" ]; then
            exit 0
        fi

        if test_configuration_option CONFIG_PREEMPT_RT; then
            PREEMPT_RT_PRESENT=1
        elif test_configuration_option CONFIG_PREEMPT_RT_FULL; then
            PREEMPT_RT_PRESENT=1
        fi

        if [ "$PREEMPT_RT_PRESENT" != "0" ]; then
            echo "The kernel you are installing for is a PREEMPT_RT kernel!";
            echo "";
            echo "The NVIDIA driver does not support real-time kernels. If you ";
            echo "are using a stock distribution kernel, please install ";
            echo "a variant of this kernel that does not have the PREEMPT_RT ";
            echo "patch set applied; if this is a custom kernel, please ";
            echo "install a standard Linux kernel.  Then try installing the ";
            echo "NVIDIA kernel module again.";
            echo "";
            if [ "$VERBOSE" = "full_output" ]; then
                echo "*** Failed PREEMPT_RT sanity check. Bailing out! ***";
                echo "";
            fi
            exit 1
        else
            exit 0
        fi
    ;;

    patch_check)
        #
        # Check for any "official" patches that may have been applied and
        # construct a description table for reporting purposes.
        #
        PATCHES=""

        for PATCH in patch-*.h; do
            if [ -f $PATCH ]; then
                echo "#include \"$PATCH\""
                PATCHES="$PATCHES "`echo $PATCH | sed -s 's/patch-\(.*\)\.h/\1/'`
            fi
        done

        echo "static struct {
                const char *short_description;
                const char *description;
              } __nv_patches[] = {"
            for i in $PATCHES; do
                echo "{ \"$i\", NV_PATCH_${i}_DESCRIPTION },"
            done
        echo "{ NULL, NULL } };"

        exit 0
    ;;

    compile_tests)
        #
        # Run a series of compile tests to determine the set of interfaces
        # and features available in the target kernel.
        #
        shift 5

        CFLAGS=$1
        shift

        for i in $*; do compile_test $i; done

        exit 0
    ;;

    dom0_sanity_check)
        #
        # Determine whether running in DOM0.
        #
        VERBOSE=$6

        if [ -n "$VGX_BUILD" ]; then
            if [ -f /proc/xen/capabilities ]; then
                if [ "`cat /proc/xen/capabilities`" == "control_d" ]; then
                    exit 0
                fi
            else
                echo "The kernel is not running in DOM0.";
                echo "";
                if [ "$VERBOSE" = "full_output" ]; then
                    echo "*** Failed DOM0 sanity check. Bailing out! ***";
                    echo "";
                fi
            fi
            exit 1
        fi
    ;;
    vgpu_kvm_sanity_check)
        #
        # Determine whether we are running a vGPU on KVM host.
        #
        VERBOSE=$6
        iommu=CONFIG_VFIO_IOMMU_TYPE1
        mdev=CONFIG_VFIO_MDEV
        kvm=CONFIG_KVM_VFIO
        vfio_pci_core=CONFIG_VFIO_PCI_CORE
        VFIO_IOMMU_PRESENT=0
        VFIO_MDEV_PRESENT=0
        KVM_PRESENT=0
        VFIO_PCI_CORE_PRESENT=0

        if [ -n "$VGX_KVM_BUILD" ]; then
            if (test_configuration_option ${iommu} || test_configuration_option ${iommu}_MODULE); then
                VFIO_IOMMU_PRESENT=1
            fi

            if (test_configuration_option ${mdev} || test_configuration_option ${mdev}_MODULE); then
                VFIO_MDEV_PRESENT=1
            fi

            if (test_configuration_option ${kvm} || test_configuration_option ${kvm}_MODULE); then
                KVM_PRESENT=1
            fi

            if (test_configuration_option ${vfio_pci_core} || test_configuration_option ${vfio_pci_core}_MODULE); then
                VFIO_PCI_CORE_PRESENT=1
            fi

            # When this sanity check is run via nvidia-installer, it sets ARCH as aarch64.
            # But, when it is run via Kbuild, ARCH is set as arm64
            if [ "$ARCH" = "aarch64" ]; then
                ARCH="arm64"
            fi

            if [ "$VFIO_IOMMU_PRESENT" != "0" ] && [ "$KVM_PRESENT" != "0" ] ; then

                # On x86_64, vGPU requires MDEV framework to be present.
                # On aarch64, vGPU requires vfio-pci-core framework to be present.
                if ([ "$ARCH" = "arm64" ] && [ "$VFIO_PCI_CORE_PRESENT" != "0" ]) ||
                   ([ "$ARCH" = "x86_64" ] && [ "$VFIO_MDEV_PRESENT" != "0" ];) then
                    exit 0
                fi
            fi

            echo "Below CONFIG options are missing on the kernel for installing";
            echo "NVIDIA vGPU driver on KVM host";
            if [ "$VFIO_IOMMU_PRESENT" = "0" ]; then
                echo "CONFIG_VFIO_IOMMU_TYPE1";
            fi

            if [ "$ARCH" = "arm64" ] &&  [ "$VFIO_PCI_CORE_PRESENT" = "0" ]; then
                echo "CONFIG_VFIO_PCI_CORE";
            fi

            if [ "$ARCH" = "x86_64" ] && [ "$VFIO_MDEV_PRESENT" = "0" ]; then
                echo "CONFIG_VFIO_MDEV";
            fi

            if [ "$KVM_PRESENT" = "0" ]; then
                echo "CONFIG_KVM";
            fi
            echo "Please install the kernel with above CONFIG options set, then";
            echo "try installing again";
            echo "";

            if [ "$VERBOSE" = "full_output" ]; then
                echo "*** Failed vGPU on KVM sanity check. Bailing out! ***";
                echo "";
            fi
            exit 1
        else
            exit 0
        fi
    ;;
    test_configuration_option)
        #
        # Check to see if the given config option is set.
        #
        OPTION=$6

        test_configuration_option $OPTION
        exit $?
    ;;

    get_configuration_option)
        #
        # Get the value of the given config option.
        #
        OPTION=$6

        get_configuration_option $OPTION
        exit $?
    ;;


    guess_module_signing_hash)
        #
        # Determine the best cryptographic hash to use for module signing,
        # to the extent that is possible.
        #

        HASH=$(get_configuration_option CONFIG_MODULE_SIG_HASH)

        if [ $? -eq 0 ] && [ -n "$HASH" ]; then
            echo $HASH
            exit 0
        else
            for SHA in 512 384 256 224 1; do
                if test_configuration_option CONFIG_MODULE_SIG_SHA$SHA; then
                    echo sha$SHA
                    exit 0
                fi
            done
        fi
        exit 1
    ;;


    test_kernel_header)
        #
        # Check for the availability of the given kernel header
        #

        CFLAGS=$6

        test_header_presence "${7}"

        exit $?
    ;;


    build_cflags)
        #
        # Generate CFLAGS for use in the compile tests
        #

        build_cflags
        echo $CFLAGS
        exit 0
    ;;

    module_symvers_sanity_check)
        #
        # Check whether Module.symvers exists and contains at least one
        # EXPORT_SYMBOL* symbol from vmlinux
        #

        if [ -n "$IGNORE_MISSING_MODULE_SYMVERS" ]; then
            exit 0
        fi

        TAB='	'

        if [ -f "$OUTPUT/Module.symvers" ] && \
             grep -e "^[^${TAB}]*${TAB}[^${TAB}]*${TAB}\+vmlinux" \
                     "$OUTPUT/Module.symvers" >/dev/null 2>&1; then
            exit 0
        fi

        echo "The Module.symvers file is missing, or does not contain any"
        echo "symbols exported from the kernel. This could cause the NVIDIA"
        echo "kernel modules to be built against a configuration that does"
        echo "not accurately reflect the actual target kernel."
        echo "The Module.symvers file check can be disabled by setting the"
        echo "environment variable IGNORE_MISSING_MODULE_SYMVERS to 1."

        exit 1
    ;;
esac
