# Rust-specific rules and macros.

load("@rules_rust//rust:defs.bzl", "rust_library", "rust_shared_library")
load(":wasm.bzl", "wasm_component")

def _kebab_to_snake(s):
    "Convert a string from kebab-case to snake_case."
    return s.replace("-", "_")

def _rust_wit_bindgen_impl(ctx):
    world = ctx.attr.world or ctx.label.name
    snake_world = _kebab_to_snake(world)

    # Generate the actual bindings in a directory called `wit`.
    bindings = ctx.actions.declare_directory("wit")
    wit_bindgen_arguments = [
        "rust",
        ctx.file.src.path,
        "--world",
        world,
        "--out-dir",
        bindings.path,
        "--generate-all",
        # Generate a public `export!` macro.
        "--pub-export-macro",
        # Make sure the generated `export!` macro uses the right namespace.
        "--default-bindings-module",
        snake_world,
    ]
    ctx.actions.run(
        inputs = [ctx.file.src],
        outputs = [bindings],
        executable = ctx.executable._wit_bindgen_bin,
        arguments = wit_bindgen_arguments,
    )

    # The wrapper `lib.rs` just republishes everything for the generated world.
    wrapper = ctx.actions.declare_file("lib.rs", sibling = bindings)
    ctx.actions.write(
        output = wrapper,
        content = """
mod wit {{
    pub mod {world};
}}

pub use wit::{world}::*;
""".format(world = snake_world),
    )

    return [DefaultInfo(files = depset([bindings, wrapper]))]

rust_wit_bindgen = rule(
    implementation = _rust_wit_bindgen_impl,
    doc = "Generate Rust bindings from a WebAssembly Interface (WIT).",
    attrs = {
        "src": attr.label(
            doc = "WIT source file or package.",
            allow_single_file = [".wit"],
        ),
        "world": attr.string(
            doc = "World to generate bindings for. Default is the target name.",
        ),
        "_wit_bindgen_bin": attr.label(
            # TODO: Use wit-bindgen-cli crate dependency instead of checking in the binary
            #   https://github.com/bazelbuild/rules_rust/discussions/2786
            default = "@wit-bindgen//:wit-bindgen",
            allow_files = True,
            executable = True,
            cfg = "exec",
        ),
    },
)

def rust_component(name, srcs, wit, world = None, deps = None):
    """
    Compile a Wasm component given a WIT package (`wit`),
    a set of Rust source files (`srcs`), and a world name.

    The default for `world` is `name`.
    """
    if world == None:
        world = name
    if deps == None:
        deps = []

    wit_name = name + " wit"
    rust_wit_bindgen(
        name = wit_name,
        src = wit,
        world = world,
    )

    lib_name = name + " lib"
    rust_library(
        name = lib_name,
        srcs = [":" + wit_name],
        deps = ["@crates//:wit-bindgen"],
        crate_name = _kebab_to_snake(world),
    )

    core_name = name + " core"
    rust_shared_library(
        name = core_name,
        srcs = srcs,
        crate_name = _kebab_to_snake(world),
        deps = deps + [
            ":" + lib_name,
            "//:wit-bindgen-cabi-realloc",
        ],
        platform = "@rules_rust//rust/platform:wasi",
    )

    wasm_component(
        name = name,
        module = ":" + core_name,
        wit = wit,
        world = world,
    )
