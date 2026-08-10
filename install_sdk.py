import subprocess
import os

env = os.environ.copy()
env['JAVA_HOME'] = r'C:\jdk-17'

sdkmanager = r'C:\Android\Sdk\cmdline-tools\latest\bin\sdkmanager.bat'

print('Accepting licenses...')
# --licenses accepts them if we pipe y
subprocess.run(f'echo y | "{sdkmanager}" --licenses', shell=True, env=env)

packages = ['platform-tools', 'platforms;android-34', 'build-tools;34.0.0']
print('Installing', packages)

subprocess.run([sdkmanager] + packages, env=env)

print('DONE!')
