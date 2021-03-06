""" Contains all logic for calling CMake for building external libraries/binaries """

load("@foreign_cc_platform_utils//:tools.bzl", "CMAKE_COMMAND")
load(":cc_toolchain_util.bzl", "absolutize_path_in_str")

def create_cmake_script(
        workspace_name,
        target_os,
        tools,
        flags,
        install_prefix,
        root,
        no_toolchain_file,
        user_cache,
        user_env,
        options,
        is_debug_mode = True):
    """ Constructs CMake script to be passed to cc_external_rule_impl.
      Args:
        workspace_name - current workspace name
        target_os - OSInfo with target operating system information, used for CMAKE_SYSTEM_NAME in
    CMake toolchain file
        tools - cc_toolchain tools (CxxToolsInfo)
        flags - cc_toolchain flags (CxxFlagsInfo)
        install_prefix - value ot pass to CMAKE_INSTALL_PREFIX
        root - sources root relative to the $EXT_BUILD_ROOT
        no_toolchain_file - if False, CMake toolchain file will be generated, otherwise not
        user_cache - dictionary with user's values of cache initializers
        user_env - dictionary with user's values for CMake environment variables
        options - other CMake options specified by user
"""
    merged_prefix_path = _merge_prefix_path(user_cache)

    toolchain_dict = _fill_crossfile_from_toolchain(workspace_name, target_os, tools, flags)
    params = None
    if no_toolchain_file:
        params = _create_cache_entries_env_vars(toolchain_dict, user_cache, user_env)
    else:
        params = _create_crosstool_file_text(toolchain_dict, user_cache, user_env)

    build_type = params.cache.get("CMAKE_BUILD_TYPE",
                                  "DEBUG" if is_debug_mode else "RELEASE")
    params.cache.update({
        "CMAKE_PREFIX_PATH": merged_prefix_path,
        "CMAKE_INSTALL_PREFIX": install_prefix,
        "CMAKE_BUILD_TYPE": build_type,
    })

    set_env_vars = " ".join([key + "=\"" + params.env[key] + "\"" for key in params.env])
    str_cmake_cache_entries = " ".join(["-D" + key + "=\"" + params.cache[key] + "\"" for key in params.cache])
    cmake_call = " ".join([
        set_env_vars,
        CMAKE_COMMAND,
        str_cmake_cache_entries,
        " ".join(options),
        "$EXT_BUILD_ROOT/" + root,
    ])

    return "\n".join(params.commands + [cmake_call])

# From CMake documentation: ;-list of directories specifying installation prefixes to be searched...
def _merge_prefix_path(user_cache):
    user_prefix = user_cache.get("CMAKE_PREFIX_PATH")
    if user_prefix != None:
        # remove it, it is gonna be merged specifically
        user_cache.pop("CMAKE_PREFIX_PATH")
        return "$EXT_BUILD_DEPS;" + user_prefix.strip("\"'")
    return "$EXT_BUILD_DEPS"

_CMAKE_ENV_VARS_FOR_CROSSTOOL = {
    "CC": struct(value = "CMAKE_C_COMPILER", replace = True),
    "CXX": struct(value = "CMAKE_CXX_COMPILER", replace = True),
    "CFLAGS": struct(value = "CMAKE_C_FLAGS_INIT", replace = False),
    "CXXFLAGS": struct(value = "CMAKE_CXX_FLAGS_INIT", replace = False),
    "ASMFLAGS": struct(value = "CMAKE_ASM_FLAGS_INIT", replace = False),
}

_CMAKE_CACHE_ENTRIES_CROSSTOOL = {
    "CMAKE_SYSTEM_NAME": struct(value = "CMAKE_SYSTEM_NAME", replace = True),
    "CMAKE_AR": struct(value = "CMAKE_AR", replace = True),
    "CMAKE_CXX_LINK_EXECUTABLE": struct(value = "CMAKE_CXX_LINK_EXECUTABLE", replace = True),
    "CMAKE_C_FLAGS": struct(value = "CMAKE_C_FLAGS_INIT", replace = False),
    "CMAKE_CXX_FLAGS": struct(value = "CMAKE_CXX_FLAGS_INIT", replace = False),
    "CMAKE_ASM_FLAGS": struct(value = "CMAKE_ASM_FLAGS_INIT", replace = False),
    "CMAKE_STATIC_LINKER_FLAGS": struct(value = "CMAKE_STATIC_LINKER_FLAGS_INIT", replace = False),
    "CMAKE_SHARED_LINKER_FLAGS": struct(value = "CMAKE_SHARED_LINKER_FLAGS_INIT", replace = False),
    "CMAKE_EXE_LINKER_FLAGS": struct(value = "CMAKE_EXE_LINKER_FLAGS_INIT", replace = False),
}

def _create_crosstool_file_text(toolchain_dict, user_cache, user_env):
    cache_entries = _dict_copy(user_cache)
    env_vars = _dict_copy(user_env)
    _move_dict_values(toolchain_dict, env_vars, _CMAKE_ENV_VARS_FOR_CROSSTOOL)
    _move_dict_values(toolchain_dict, cache_entries, _CMAKE_CACHE_ENTRIES_CROSSTOOL)

    lines = []
    for key in toolchain_dict:
        if ("CMAKE_AR" == key):
            lines += ["set({} \"{}\" {})".format(key, toolchain_dict[key], "CACHE FILEPATH \"Archiver\"")]
            continue
        lines += ["set({} \"{}\")".format(key, toolchain_dict[key])]

    cache_entries.update({
        "CMAKE_TOOLCHAIN_FILE": "crosstool_bazel.cmake",
    })
    return struct(
        commands = ["cat > crosstool_bazel.cmake <<EOF\n" + "\n".join(lines) + "\nEOF\n"],
        env = env_vars,
        cache = cache_entries,
    )

def _dict_copy(d):
    out = {}
    if d:
        out.update(d)
    return out

def _create_cache_entries_env_vars(toolchain_dict, user_cache, user_env):
    toolchain_dict.pop("CMAKE_SYSTEM_NAME")  # specify this only in a toolchain file

    _move_dict_values(toolchain_dict, user_env, _CMAKE_ENV_VARS_FOR_CROSSTOOL)
    _move_dict_values(toolchain_dict, user_cache, _CMAKE_CACHE_ENTRIES_CROSSTOOL)

    merged_env = _translate_from_toolchain_file(toolchain_dict, _CMAKE_ENV_VARS_FOR_CROSSTOOL)
    merged_cache = _translate_from_toolchain_file(toolchain_dict, _CMAKE_CACHE_ENTRIES_CROSSTOOL)

    # anything left in user's env_entries does not correspond to anything defined by toolchain
    # => simple merge
    merged_env.update(user_env)
    merged_cache.update(user_cache)

    return struct(
        commands = [],
        env = merged_env,
        cache = merged_cache,
    )

def _translate_from_toolchain_file(toolchain_dict, descriptor_map):
    reverse = _reverse_descriptor_dict(descriptor_map)
    cl_keyed_toolchain = dict()

    keys = toolchain_dict.keys()
    for key in keys:
        env_var_key = reverse.get(key)
        if env_var_key:
            cl_keyed_toolchain[env_var_key.value] = toolchain_dict.pop(key)
    return cl_keyed_toolchain

def _merge_toolchain_and_user_values(toolchain_dict, user_dict, descriptor_map):
    _move_dict_values(toolchain_dict, user_dict, descriptor_map)
    cl_keyed_toolchain = _translate_from_toolchain_file(toolchain_dict, descriptor_map)

    # anything left in user's env_entries does not correspond to anything defined by toolchain
    # => simple merge
    cl_keyed_toolchain.update(user_dict)
    return cl_keyed_toolchain

def _reverse_descriptor_dict(dict):
    out_dict = {}

    for key in dict:
        value = dict[key]
        out_dict[value.value] = struct(value = key, replace = value.replace)

    return out_dict

def _move_dict_values(target, source, descriptor_map):
    keys = source.keys()
    for key in keys:
        existing = descriptor_map.get(key)
        if existing:
            value = source.pop(key)
            if existing.replace or target.get(existing.value) == None:
                target[existing.value] = value
            else:
                target[existing.value] = _merge(target[existing.value], value)

def _merge(str1, str2):
    return str1.strip("\"'") + " " + str2.strip("\"'")

def _fill_crossfile_from_toolchain(workspace_name, target_os, tools, flags):
    os_name = "Linux"
    if target_os.is_win:
        os_name = "Windows"
    if target_os.is_osx:
        os_name = "Apple"
    dict = {
        "CMAKE_SYSTEM_NAME": os_name,
    }

    _sysroot = _find_in_cc_or_cxx(flags, "sysroot")
    if _sysroot:
        dict["CMAKE_SYSROOT"] = _absolutize(workspace_name, _sysroot)

    _ext_toolchain_cc = _find_flag_value(flags.cc, "gcc_toolchain")
    if _ext_toolchain_cc:
        dict["CMAKE_C_COMPILER_EXTERNAL_TOOLCHAIN"] = _absolutize(workspace_name, _ext_toolchain_cc)

    _ext_toolchain_cxx = _find_flag_value(flags.cxx, "gcc_toolchain")
    if _ext_toolchain_cxx:
        dict["CMAKE_CXX_COMPILER_EXTERNAL_TOOLCHAIN"] = _absolutize(workspace_name, _ext_toolchain_cxx)

    if tools.cc:
        dict["CMAKE_C_COMPILER"] = _absolutize(workspace_name, tools.cc)
    if tools.cxx:
        dict["CMAKE_CXX_COMPILER"] = _absolutize(workspace_name, tools.cxx)

    if tools.cxx_linker_static:
        dict["CMAKE_AR"] = _absolutize(workspace_name, tools.cxx_linker_static)

    if tools.cxx_linker_executable and tools.cxx_linker_executable != tools.cxx:
        normalized_path = _absolutize(workspace_name, tools.cxx_linker_executable)
        dict["CMAKE_CXX_LINK_EXECUTABLE"] = " ".join([
            normalized_path,
            "<FLAGS>",
            "<CMAKE_CXX_LINK_FLAGS>",
            "<LINK_FLAGS>",
            "<OBJECTS>",
            "-o <TARGET>",
            "<LINK_LIBRARIES>",
        ])

    if flags.cc:
        dict["CMAKE_C_FLAGS_INIT"] = _join_flags_list(workspace_name, flags.cc)
    if flags.cxx:
        dict["CMAKE_CXX_FLAGS_INIT"] = _join_flags_list(workspace_name, flags.cxx)
    if flags.assemble:
        dict["CMAKE_ASM_FLAGS_INIT"] = _join_flags_list(workspace_name, flags.assemble)

    # todo this options are needed, but cause a bug because the flags are put in wrong order => keep this line
    #    if flags.cxx_linker_static:
    #        lines += [_set_list(ctx, "CMAKE_STATIC_LINKER_FLAGS_INIT", flags.cxx_linker_static)]
    if flags.cxx_linker_shared:
        dict["CMAKE_SHARED_LINKER_FLAGS_INIT"] = _join_flags_list(workspace_name, flags.cxx_linker_shared)
    if flags.cxx_linker_executable:
        dict["CMAKE_EXE_LINKER_FLAGS_INIT"] = _join_flags_list(workspace_name, flags.cxx_linker_executable)

    return dict

def _find_in_cc_or_cxx(flags, flag_name_no_dashes):
    _value = _find_flag_value(flags.cxx, flag_name_no_dashes)
    if _value:
        return _value
    return _find_flag_value(flags.cc, flag_name_no_dashes)

def _find_flag_value(list, flag_name_no_dashes):
    one_dash = "-" + flag_name_no_dashes.lstrip(" ")
    two_dash = "--" + flag_name_no_dashes.lstrip(" ")

    check_for_value = False
    for value in list:
        value = value.lstrip(" ")
        if check_for_value:
            return value.lstrip(" =")
        _tail = _tail_if_starts_with(value, one_dash)
        _tail = _tail_if_starts_with(value, two_dash) if _tail == None else _tail
        if _tail != None and len(_tail) > 0:
            return _tail.lstrip(" =")
        if _tail != None:
            check_for_value = True

def _tail_if_starts_with(str, start):
    if (str.startswith(start)):
        return str[len(start):]
    return None

def _absolutize(workspace_name, text):
    return absolutize_path_in_str(workspace_name, "$EXT_BUILD_ROOT/", text)

def _join_flags_list(workspace_name, flags):
    return " ".join([_absolutize(workspace_name, flag) for flag in flags])

export_for_test = struct(
    absolutize = _absolutize,
    tail_if_starts_with = _tail_if_starts_with,
    find_flag_value = _find_flag_value,
    fill_crossfile_from_toolchain = _fill_crossfile_from_toolchain,
    move_dict_values = _move_dict_values,
    reverse_descriptor_dict = _reverse_descriptor_dict,
    merge_toolchain_and_user_values = _merge_toolchain_and_user_values,
    CMAKE_ENV_VARS_FOR_CROSSTOOL = _CMAKE_ENV_VARS_FOR_CROSSTOOL,
    CMAKE_CACHE_ENTRIES_CROSSTOOL = _CMAKE_CACHE_ENTRIES_CROSSTOOL,
)
