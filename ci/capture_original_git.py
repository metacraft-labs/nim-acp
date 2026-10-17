"""Read-only initial-checkout factory proof; no hook admission or mutation."""
import hashlib, json, os, pathlib, shutil, stat, subprocess, tempfile, re, sys
P = pathlib.Path

def require(ok, reason):
    if not ok: raise RuntimeError(reason)

def sha(data): return hashlib.sha256(data).hexdigest()

def identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid, info.st_size, info.st_mtime_ns, info.st_ctime_ns)

def regular(path):
    before = path.lstat()
    require(stat.S_ISREG(before.st_mode), 'Nonregular authority')
    with path.open('rb') as stream:
        opened = os.fstat(stream.fileno())
        require((before.st_dev, before.st_ino) == (opened.st_dev, opened.st_ino), 'Authority replaced')
        body = stream.read()
        after = os.fstat(stream.fileno())
    require(identity(opened) == identity(after) and identity(path.lstat()) == identity(before), 'Authority changed')
    return dict(sha=sha(body), mode=stat.S_IMODE(before.st_mode), dev=before.st_dev, ino=before.st_ino)

def directory(path):
    row=path.lstat()
    require(stat.S_ISDIR(row.st_mode) and not path.is_symlink(), 'Directory authority refused')
    return dict(dev=row.st_dev,ino=row.st_ino,mode=stat.S_IMODE(row.st_mode),uid=row.st_uid,gid=row.st_gid)

def alias(path):
    row=path.lstat()
    require(stat.S_ISLNK(row.st_mode), 'Alias authority refused')
    return dict(dev=row.st_dev,ino=row.st_ino,mode=stat.S_IMODE(row.st_mode),target=os.readlink(path))

def inventory(directory):
    require(directory.is_dir() and not directory.is_symlink(), 'Non-directory hooks')
    result = {}
    for path in sorted(directory.iterdir()):
        require(path.name.endswith('.sample'), 'Non-sample initial hook refused')
        row = regular(path)
        result[path.name] = dict(sha=row['sha'], mode=row['mode'])
    require(result, 'Empty initial sample inventory')
    return result

def read_creator_binding(path):
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, 'Duplicate creator binding field')
            result[key] = value
        return result
    value = json.loads(P(path).read_text(), object_pairs_hook=unique_object)
    require(type(value) is dict and set(value) == {
        'schema', 'statEncoding', 'root', 'creator', 'principal',
        'inheritedExecPath', 'version', 'execPath', 'creationUmask'}, 'Creator binding fields differ')
    require(value['schema'] == 'nim-acp-checkout-creator.v2' and
            value['statEncoding'] == 'decimal-v1', 'Creator binding schema differs')
    for field in ('root', 'creator', 'version', 'execPath'):
        require(type(value[field]) is str and value[field], 'Creator binding text malformed: ' + field)
    require(value['inheritedExecPath'] is None or type(value['inheritedExecPath']) is str,
            'Creator binding exec selector malformed')
    require(type(value['creationUmask']) is int and 0 <= value['creationUmask'] <= 0o777,
            'Creator creation umask malformed')
    row = value['principal']
    require(type(row) is dict and set(row) == {'sha', 'mode', 'dev', 'ino'},
            'Creator principal fields differ')
    require(type(row['sha']) is str and re.fullmatch(r'[0-9a-f]{64}', row['sha']) is not None,
            'Creator digest malformed')
    require(type(row['mode']) is int and 0 <= row['mode'] <= 0o7777,
            'Creator mode malformed')
    for field in ('dev', 'ino'):
        require(type(row[field]) is str and re.fullmatch(r'0|[1-9][0-9]*', row[field]) is not None,
                'Creator decimal principal malformed: ' + field)
        row[field] = int(row[field])
    return value

def capture(root, receipt, creator_binding=None):
    require(root == P.cwd() and root.is_absolute(), 'Wrong owning cwd')
    for path in (root, *root.parents, root/'.git', root/'.git/hooks'):
        require(not path.is_symlink(), 'Symlink authority refused')
    require((root/'.git').is_dir(), 'Ordinary initial checkout required')
    forbidden = ('GIT_CONFIG','GIT_DIR','GIT_WORK_TREE','GIT_COMMON_DIR','GIT_TEMPLATE_DIR','GIT_CONFIG_PARAMETERS','GIT_CONFIG_COUNT','GIT_INDEX_FILE','GIT_OBJECT_DIRECTORY','GIT_ALTERNATE_OBJECT_DIRECTORIES')
    require(not any(os.environ.get(name) for name in forbidden), 'Inherited Git selector refused')
    require(not any(name.startswith(('GIT_CONFIG_KEY_', 'GIT_CONFIG_VALUE_')) for name in os.environ), 'Counted config refused')
    binding = read_creator_binding(creator_binding) if creator_binding else None
    image = P(binding['creator']).resolve(strict=True) if binding else P(shutil.which('git')).resolve(strict=True)
    principal = regular(image)
    if binding:
        require(binding['root']==str(root), 'Creator binding root differs')
        require(principal==binding['principal'], 'Checkout-time creator image changed')
        require(os.environ.get('GIT_EXEC_PATH')==binding['inheritedExecPath'], 'Checkout-time Git exec selector changed')
    env = dict(os.environ, GIT_OPTIONAL_LOCKS='0', GIT_NO_LAZY_FETCH='1')
    def git(*args): return subprocess.run([str(image), *args], cwd=root, env=env, capture_output=True, check=False)
    for key in ('init.templateDir', 'core.hooksPath', 'core.sharedRepository'):
        require(git('config','--get-all',key).returncode == 1, 'Configured constructor policy refused: '+key)
    if binding:
        require(git('--exec-path').returncode==0 and git('--exec-path').stdout.decode().strip()==binding['execPath'], 'Checkout-time exec path changed')
    def checked(*args):
        result = git(*args)
        require(result.returncode == 0, 'Git command failed: '+args[0])
        return result.stdout
    if binding:
        require(checked('--version').decode().strip()==binding['version'], 'Checkout-time creator version changed')
    def head():
        oid = checked('rev-parse','HEAD').decode().strip()
        require(re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', oid) is not None, 'Invalid full HEAD identity')
        return oid
    require(checked('rev-parse','--show-toplevel').strip() == os.fsencode(root), 'Foreign root')
    require(checked('status','--porcelain=v1','--untracked-files=no') == b'', 'Dirty tracked source')
    def source():
        listing = git('ls-files','--stage','-z')
        require(listing.returncode == 0, 'Source listing failed')
        rows = []
        for entry in listing.stdout.split(b'\0'):
            if not entry: continue
            fields, name = entry.split(b'\t', 1)
            mode, oid, stage = fields.split()
            require(stage == b'0', 'Unmerged initial source')
            path = root / os.fsdecode(name)
            if mode == b'120000':
                require(path.is_symlink(), 'Source symlink changed')
                body = alias(path)
            else:
                require(mode in (b'100644', b'100755'), 'Unsupported source kind')
                body = regular(path)
            rows.append([os.fsdecode(entry), body])
        return rows
    directories={str(path):directory(path) for path in (root,root/'.git',root/'.git/hooks')}
    before = dict(directories=directories, source=source(), index=regular(root/'.git/index'), config=regular(root/'.git/config'), hooks=inventory(root/'.git/hooks'), head=head(), hookPrincipals={path.name: regular(path) for path in (root/'.git/hooks').iterdir()})
    # Actual creator's default constructor discovers its own template closure.
    # Isolate configuration only AFTER refusing caller selectors; preserve umask.
    probe_env = dict(env, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull)
    with tempfile.TemporaryDirectory(prefix='acp-original-git-factory-') as temporary:
        probe = P(temporary)/'probe'
        subprocess.run([str(image),'init',str(probe)],env=probe_env,check=True,capture_output=True,
                        umask=binding['creationUmask'] if binding else -1)
        factory = inventory(probe/'.git/hooks')
        if factory != before['hooks']:
            # Diagnostic failure must never replace the original refusal.
            try:
                print(json.dumps(dict(event='acp-original-factory-mismatch',
                    creator=str(image), principal=principal,
                    version=checked('--version').decode().strip(),
                    execPath=checked('--exec-path').decode().strip(),
                    inheritedExecPath=os.environ.get('GIT_EXEC_PATH'),
                    checkout=before['hooks'], factory=factory), sort_keys=True),
                    file=sys.stderr, flush=True)
            except Exception:
                pass
            require(False, 'Actual creator factory differs from checkout samples')
    require(regular(image) == principal, 'Creator image changed')
    require(regular(root/'.git/index') == before['index'] and regular(root/'.git/config') == before['config'] and inventory(root/'.git/hooks') == before['hooks'], 'Checkout changed during capture')
    require(head() == before['head'], 'HEAD changed')
    require({path.name: regular(path) for path in (root/'.git/hooks').iterdir()} == before['hookPrincipals'], 'Original hook identity changed')
    require(source() == before['source'], 'Tracked source changed')
    require({str(path):directory(path) for path in (root,root/'.git',root/'.git/hooks')}==directories, 'Directory principal changed')
    with receipt.open('x') as output:
        json.dump(dict(root=str(root), creator=str(image), principal=principal, before=before, native=False, transition=False), output, indent=2)
        output.write('\n')

def bind_creator(root, destination):
    require(root==P.cwd() and root.is_absolute(), 'Wrong creator-binding cwd')
    image=P(shutil.which('git')).resolve(strict=True)
    principal=regular(image)
    results={}
    for key,argv in (('version',['--version']),('execPath',['--exec-path'])):
        result=subprocess.run([str(image),*argv],cwd=root,capture_output=True,check=True)
        results[key]=result.stdout.decode().strip()
    require(regular(image)==principal, 'Creator image changed during binding')
    with destination.open('x') as output:
        json.dump(dict(schema='nim-acp-checkout-creator.v2',statEncoding='decimal-v1',
            root=str(root),creator=str(image),principal=dict(principal,dev=str(principal['dev']),ino=str(principal['ino'])),
            inheritedExecPath=os.environ.get('GIT_EXEC_PATH'),
            creationUmask=int(subprocess.check_output([sys.executable, '-c', 'import os; print(os.umask(0))'])),**results),output,indent=2)
        output.write('\n')

if __name__ == '__main__':
    if sys.argv[1]=='--bind-creator':
        bind_creator(P.cwd(),P(sys.argv[2]))
    else:
        capture(P.cwd(),P(sys.argv[1]),P(sys.argv[2]) if len(sys.argv)>2 else None)
