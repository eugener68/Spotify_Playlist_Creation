import glob
from os.path import basename, exists, join
import sys
import packaging.version

import sh
from pythonforandroid.recipe import CythonRecipe
from pythonforandroid.toolchain import current_directory, shprint, info


class KivyPatchedRecipe(CythonRecipe):
    # Match your app's Kivy pin
    version = '2.3.1'
    url = 'https://github.com/kivy/kivy/archive/{version}.zip'
    name = 'kivy'

    depends = ['sdl2', 'pyjnius', 'setuptools']
    python_depends = ['certifi', 'chardet', 'idna', 'requests', 'urllib3']

    def prebuild_arch(self, arch):
        super().prebuild_arch(arch)
        # Inject a Python 3 compatible alias for long in weakproxy.pyx before cythonizing
        build_dir = self.get_build_dir(arch.arch)
        target = join(build_dir, 'kivy', 'weakproxy.pyx')
        try:
            with open(target, 'r', encoding='utf-8') as f:
                content = f.read()
            changed = False
            if 'def __long__(self):' in content or ' return long(' in content:
                # Prepend alias for long and also replace return long(...) with int(...) for safety
                if 'try:\n    long' not in content:
                    content = 'try:\n    long\nexcept NameError:\n    long = int\n\n' + content
                    changed = True
                new_content = content.replace('return long(', 'return int(')
                if new_content != content:
                    content = new_content
                    changed = True
            if changed:
                with open(target, 'w', encoding='utf-8') as f:
                    f.write(content)
                info('Patched Kivy weakproxy.pyx to be Python 3 / Cython 3 compatible (long -> int)')
        except FileNotFoundError:
            info('Kivy weakproxy.pyx not found yet; will proceed without pre-patch')

    def cythonize_build(self, env, build_dir='.'):
        # Keep upstream behavior of copying include directory if present
        super().cythonize_build(env, build_dir=build_dir)
        if not exists(join(build_dir, 'kivy', 'include')):
            return
        with current_directory(build_dir):
            build_libs_dirs = glob.glob(join('build', 'lib.*'))
            for dirn in build_libs_dirs:
                shprint(sh.cp, '-r', join('kivy', 'include'), join(dirn, 'kivy'))

    def cythonize_file(self, env, build_dir, filename):
        # Ignore files not relevant to Android
        do_not_cythonize = ['window_x11.pyx']
        if basename(filename) in do_not_cythonize:
            return
        super().cythonize_file(env, build_dir, filename)

    def get_recipe_env(self, arch):
        env = super().get_recipe_env(arch)
        env['NDKPLATFORM'] = 'NOTNONE'
        if 'sdl2' in self.ctx.recipe_build_order:
            env['USE_SDL2'] = '1'
            env['KIVY_SPLIT_EXAMPLES'] = '1'
            sdl2_mixer_recipe = self.get_recipe('sdl2_mixer', self.ctx)
            sdl2_image_recipe = self.get_recipe('sdl2_image', self.ctx)
            env['KIVY_SDL2_PATH'] = ':'.join([
                join(self.ctx.bootstrap.build_dir, 'jni', 'SDL', 'include'),
                *sdl2_image_recipe.get_include_dirs(arch),
                *sdl2_mixer_recipe.get_include_dirs(arch),
                join(self.ctx.bootstrap.build_dir, 'jni', 'SDL2_ttf'),
            ])
        return env


recipe = KivyPatchedRecipe()
