from pythonforandroid.recipe import CythonRecipe
from pythonforandroid.toolchain import shprint, current_directory, info
from pythonforandroid.patching import will_build
import sh
from os.path import join

class PyjniusPatchedRecipe(CythonRecipe):
    version = '1.6.1'
    url = 'https://github.com/kivy/pyjnius/archive/{version}.zip'
    name = 'pyjnius'
    depends = [('genericndkbuild', 'sdl2'), 'six']
    site_packages_name = 'jnius'
    patches = [('genericndkbuild_jnienv_getter.patch', will_build('genericndkbuild'))]

    def prebuild_arch(self, arch):
        super().prebuild_arch(arch)
        # Apply in-tree text patch before cythonization
        build_dir = self.get_build_dir(arch.arch)
        target = join(build_dir, 'jnius', 'jnius_utils.pxi')
        try:
            with open(target, 'r', encoding='utf-8') as f:
                content = f.read()
            if 'isinstance(arg, long)' in content:
                new = content.replace('isinstance(arg, long)', 'isinstance(arg, int)')
                if 'try:\n    long' not in new:
                    new = 'try:\n    long\nexcept NameError:\n    long = int\n\n' + new
                with open(target, 'w', encoding='utf-8') as f:
                    f.write(new)
                info('Patched pyjnius jnius_utils.pxi (removed Python2 long)')
        except FileNotFoundError:
            info('Could not locate jnius_utils.pxi for patching (will continue)')

    def get_recipe_env(self, arch):
        env = super().get_recipe_env(arch)
        env['NDKPLATFORM'] = 'NOTNONE'
        return env

    def postbuild_arch(self, arch):
        super().postbuild_arch(arch)
        info('Copying pyjnius java class to classes build dir (patched recipe)')
        with current_directory(self.get_build_dir(arch.arch)):
            shprint(sh.cp, '-a', join('jnius', 'src', 'org'), self.ctx.javaclass_dir)

recipe = PyjniusPatchedRecipe()
