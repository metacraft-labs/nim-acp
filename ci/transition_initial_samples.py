"""Proposed initial-sample transition. Call only before owning-shell activation."""
import ctypes, hashlib, importlib.util, json, os, pathlib, stat, subprocess, sys, tempfile, contextlib, secrets
P=pathlib.Path
spec=importlib.util.spec_from_file_location('capture', P(__file__).with_name('capture_original_git.py'))
c=importlib.util.module_from_spec(spec); spec.loader.exec_module(c)

def move_exclusive(source_fd, source_name, destination_fd, destination_name):
    """Move the lexical node without replacing any destination, or refuse."""
    libc=ctypes.CDLL(None,use_errno=True)
    if sys.platform.startswith('linux'):
        function=getattr(libc,'renameat2',None); flags=1  # RENAME_NOREPLACE
    elif sys.platform=='darwin':
        function=getattr(libc,'renameatx_np',None); flags=4  # RENAME_EXCL
    else:
        raise RuntimeError('No supported exclusive rename authority')
    c.require(function is not None, 'Exclusive rename unavailable')
    function.argtypes=[ctypes.c_int,ctypes.c_char_p,ctypes.c_int,ctypes.c_char_p,ctypes.c_uint]
    function.restype=ctypes.c_int
    if function(source_fd,os.fsencode(source_name),destination_fd,os.fsencode(destination_name),flags)!=0:
        code=ctypes.get_errno()
        raise OSError(code,os.strerror(code))

def transition(receipt, selected):
    root=P.cwd(); proof=json.loads(receipt.read_text()); initial=proof['before']
    c.require(str(root)==proof['root'], 'Wrong owning root')
    selected=selected.resolve(strict=True)
    c.require(selected.is_absolute() and selected.is_file() and os.access(selected,os.X_OK), 'Missing selected Git')
    selected_principal=c.regular(selected)
    creator=P(proof['creator']); c.require(c.regular(creator)==proof['principal'], 'Original Git changed')
    hooks=root/'.git/hooks'
    # All originals survive by inode in this exclusively created private directory.
    held={}
    def hold(path):
        for part in (path,*path.parents):
            c.require(not part.is_symlink(), 'Symlink directory authority')
        descriptor=os.open(path,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
        observed=os.fstat(descriptor)
        c.require((observed.st_dev,observed.st_ino)==(path.lstat().st_dev,path.lstat().st_ino), 'Directory changed on open')
        held[path]=(descriptor,observed)
        return descriptor
    root_fd=hold(root); common_fd=hold(root/'.git'); hooks_fd=hold(hooks)
    c.require({str(path):c.directory(path) for path in (root,root/'.git',hooks)}==initial['directories'], 'Original directory principal changed')
    env=dict(os.environ,GIT_OPTIONAL_LOCKS='0',GIT_NO_LAZY_FETCH='1',GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL=os.devnull)
    # The selected owning factory uses its own default executable/template
    # role, independently of any authenticated original creator exec selector.
    selected_env=dict(env)
    selected_env.pop('GIT_EXEC_PATH',None)
    selected_exec=subprocess.run([str(selected),'--exec-path'],env=selected_env,check=True,capture_output=True).stdout.decode().strip()
    c.require(selected_exec, 'Selected default exec path absent')
    result=dict(success=False,originals=initial['hookPrincipals'],changed=[],selectedExecPath=selected_exec)
    postimages={}
    retired=[]
    def check_hooks():
        expected=dict(initial['hookPrincipals'])
        expected.update(postimages)
        for name in retired: expected.pop(name)
        c.require({p.name:c.regular(p) for p in hooks.iterdir()}==expected, 'Unexpected whole hook postimage')
        c.require(all(c.regular((backup if (backup/name).exists() else hooks)/name)==row for name,row in initial['hookPrincipals'].items()), 'Preserved original changed')
    def fixed_state():
        for path,(descriptor,observed) in held.items():
            for part in (path,*path.parents):
                c.require(not part.is_symlink(), 'Directory ancestor changed')
            current=path.lstat(); opened=os.fstat(descriptor)
            c.require((current.st_dev,current.st_ino,current.st_mode,current.st_uid,current.st_gid)==(observed.st_dev,observed.st_ino,observed.st_mode,observed.st_uid,observed.st_gid) and (opened.st_dev,opened.st_ino)==(observed.st_dev,observed.st_ino), 'Held directory identity changed')
        c.require(c.regular(creator)==proof['principal'] and c.regular(selected)==selected_principal, 'Git principal changed')
        c.require(c.regular(root/'.git/index')==initial['index'] and c.regular(root/'.git/config')==initial['config'], 'Index/config changed')
        head=subprocess.run([str(creator),'rev-parse','HEAD'],cwd=root,env=env,capture_output=True,check=True).stdout.decode().strip()
        c.require(head==initial['head'], 'HEAD changed')
        for entry, observed in initial['source']:
            fields,name=entry.split('\t',1); path=root/name
            if fields.startswith('120000 '):
                c.require(c.alias(path)==observed, 'Source alias changed')
            else: c.require(c.regular(path)==observed, 'Source changed')
    try:
        fixed_state()
        c.require({p.name:c.regular(p) for p in hooks.iterdir()}==initial['hookPrincipals'], 'Initial hook principals changed')
        # mkdirat is create-only under the already authenticated held common dir.
        backup_name='acp-initial-samples-preserved-'+secrets.token_hex(12)
        os.mkdir(backup_name,mode=0o700,dir_fd=common_fd)
        backup=root/'.git'/backup_name
        backup_fd=hold(backup)
        c.require(stat.S_IMODE(os.fstat(backup_fd).st_mode)==0o700, 'Private backup mode differs')
        result['backup']=str(backup)
        os.mkdir('retired',mode=0o700,dir_fd=backup_fd)
        retired_fd=hold(backup/'retired')
        os.mkdir('rollback-added',mode=0o700,dir_fd=backup_fd)
        rollback_added_fd=hold(backup/'rollback-added')
        fixed_state()
        with contextlib.nullcontext(backup) as directory:
            fixture=P(directory)/'selected-factory'
            # The child starts inside the held private directory, not a lexical
            # path that could have been replaced between validation and exec.
            subprocess.run([str(selected),'init','selected-factory'],preexec_fn=lambda: os.fchdir(backup_fd),env=selected_env,check=True,capture_output=True)
            materialized=fixture/'.git/hooks'; materialized_fd=hold(materialized); desired=c.inventory(materialized)
            # A backup hard link preserves each exact original inode and mode.
            for name in sorted(initial['hooks']):
                fixed_state()
                c.require(c.regular(hooks/name)==initial['hookPrincipals'][name], 'Original replaced before preservation')
                os.link(name,name,src_dir_fd=hooks_fd,dst_dir_fd=backup_fd,follow_symlinks=False)
                c.require(c.regular(backup/name)==initial['hookPrincipals'][name], 'Backup identity differs')
            for name in sorted(desired):
                fixed_state(); check_hooks()
                if name in initial['hooks']:
                    c.require(c.regular(backup/name)==initial['hookPrincipals'][name], 'Preserved original changed')
                    c.require(c.regular(hooks/name)==initial['hookPrincipals'][name], 'Unchanged original replaced')
                    # Rename a genuine selected-Git constructor output; no body rendering.
                    os.replace(name,name,src_dir_fd=materialized_fd,dst_dir_fd=hooks_fd)
                else:
                    # linkat is create-only, including against dangling symlinks.
                    # The selected factory keeps its own link throughout rollback.
                    os.link(name,name,src_dir_fd=materialized_fd,dst_dir_fd=hooks_fd,follow_symlinks=False)
                result['changed'].append(name)
                row=c.regular(hooks/name)
                c.require(dict(sha=row['sha'],mode=row['mode'])==desired[name], 'Constructor postimage changed')
                postimages[name]=row
                check_hooks()
            for name in sorted(set(initial['hooks']) - set(desired)):
                fixed_state(); check_hooks()
                c.require(c.regular(backup/name)==initial['hookPrincipals'][name], 'Retired original backup changed')
                c.require(c.regular(hooks/name)==initial['hookPrincipals'][name], 'Retired original replaced')
                # Preserve the moved lexical node even if a concurrent replacement
                # occurred after the precheck. Unknown moved nodes are never deleted.
                move_exclusive(hooks_fd,name,retired_fd,name)
                result.setdefault('retirementMoves',[]).append(name)
                c.require(c.regular(backup/'retired'/name)==initial['hookPrincipals'][name], 'Moved retirement principal differs')
                retired.append(name)
                result['retired']=retired.copy()
                check_hooks()
            fixed_state()
            c.require(c.inventory(hooks)==desired, 'Selected inventory mismatch')
            c.require({p.name:c.regular(p) for p in backup.iterdir() if p.name not in ('selected-factory','retired','rollback-added')}==initial['hookPrincipals'], 'Original backup changed')
            result.update(success=True,selected=str(selected),selectedPrincipal=selected_principal,desired=desired)
    except BaseException as error:
        result['error']=repr(error)
        # A rollback is admitted only against the complete known postimage.
        # Any foreign drift retains originals and the partial journal untouched.
        try:
            fixed_state()
            check_hooks()
            for name in reversed(retired.copy()):
                fixed_state(); check_hooks()
                # Create-only restoration refuses even dangling occupied names.
                move_exclusive(retired_fd,name,hooks_fd,name)
                c.require(c.regular(hooks/name)==initial['hookPrincipals'][name], 'Restored retirement principal differs')
                retired.remove(name)
                result['retired']=retired.copy()
            for name in reversed(result['changed'].copy()):
                fixed_state(); check_hooks()
                if name in initial['hooks']:
                    os.replace(name,name,src_dir_fd=backup_fd,dst_dir_fd=hooks_fd)
                else:
                    c.require(c.regular(hooks/name)==postimages[name], 'Added constructor output changed')
                    move_exclusive(hooks_fd,name,rollback_added_fd,name)
                    result.setdefault('rollbackAddedMoves',[]).append(name)
                    c.require(c.regular(backup/'rollback-added'/name)==postimages[name], 'Moved added rollback principal differs')
                postimages.pop(name)
                result['changed'].remove(name)
            c.require({p.name:c.regular(p) for p in hooks.iterdir()}==initial['hookPrincipals'], 'Rollback original identity mismatch')
            result['rollbackOriginalsExact']=True
        except BaseException as rollback_error:
            result['rollbackRefused']=repr(rollback_error)
        raise
    finally:
        if 'backup_fd' in locals():
            descriptor=os.open('transition-result.json',os.O_CREAT|os.O_EXCL|os.O_WRONLY|os.O_NOFOLLOW,0o600,dir_fd=backup_fd)
            with os.fdopen(descriptor,'w') as output: json.dump(result,output,indent=2)
        for descriptor,_ in held.values(): os.close(descriptor)
    return result

if __name__=='__main__':
    transition(P(sys.argv[1]).resolve(strict=True),P(sys.argv[2]))
