import subprocess
import os
import time

env = os.environ.copy()
env['JAVA_HOME'] = r'C:\jdk-17'

sdkmanager = r'C:\Android\Sdk\cmdline-tools\latest\bin\sdkmanager.bat'

def run_with_yes(cmd):
    print("Running:", cmd)
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
    
    # Read output in a separate thread so it doesn't block
    import threading
    def print_out():
        for line in p.stdout:
            # print(line, end='') # uncomment to see everything
            pass
            
    t = threading.Thread(target=print_out)
    t.start()
    
    while p.poll() is None:
        try:
            p.stdin.write('y\n')
            p.stdin.flush()
        except Exception:
            pass
        time.sleep(0.1)
    
    t.join()
    print("Finished with code", p.returncode)

print('Accepting licenses...')
run_with_yes([sdkmanager, '--licenses'])

packages = ['platform-tools', 'platforms;android-34', 'build-tools;34.0.0']
print('Installing', packages)
run_with_yes([sdkmanager] + packages)

print('DONE!')
