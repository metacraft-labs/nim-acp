"""Proposed initial-sample transition. Call only before owning-shell activation."""
import hashlib, importlib.util, json, os, pathlib, stat, subprocess, sys, tempfile, contextlib, secrets
P=pathlib.Path
spec=importlib.util.spec_from_file_location('capture', P(__file__).with_name('capture_original_git.py'))
c=importlib.util.module_from_spec(spec); spec.loader.exec_module(c)

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
    result=dict(success=False,originals=initial['hookPrincipals'],changed=[])
    postimages={}
    def check_hooks():
        expected=dict(initial['hookPrincipals'])
        expected.update(postimages)
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
        fixed_state()
        with contextlib.nullcontext(backup) as directory:
            fixture=P(directory)/'selected-factory'
            # The child starts inside the held private directory, not a lexical
            # path that could have been replaced between validation and exec.
            subprocess.run([str(selected),'init','selected-factory'],preexec_fn=lambda: os.fchdir(backup_fd),env=env,check=True,capture_output=True)
            materialized=fixture/'.git/hooks'; materialized_fd=hold(materialized); desired=c.inventory(materialized)
            c.require(set(desired)==set(initial['hooks']), 'Selected factory inventory differs')
            # A backup hard link preserves each exact original inode and mode.
            for name in sorted(initial['hooks']):
                fixed_state()
                c.require(c.regular(hooks/name)==initial['hookPrincipals'][name], 'Original replaced before preservation')
                os.link(name,name,src_dir_fd=hooks_fd,dst_dir_fd=backup_fd,follow_symlinks=False)
                c.require(c.regular(backup/name)==initial['hookPrincipals'][name], 'Backup identity differs')
            for name in sorted(desired):
                fixed_state(); check_hooks()
                c.require(c.regular(backup/name)==initial['hookPrincipals'][name], 'Preserved original changed')
                c.require(c.regular(hooks/name)==initial['hookPrincipals'][name], 'Unchanged original replaced')
                # Rename a genuine selected-Git constructor output; no body rendering.
                os.replace(name,name,src_dir_fd=materialized_fd,dst_dir_fd=hooks_fd)
                result['changed'].append(name)
                row=c.regular(hooks/name)
                c.require(dict(sha=row['sha'],mode=row['mode'])==desired[name], 'Constructor postimage changed')
                postimages[name]=row
                check_hooks()
            fixed_state()
            c.require(c.inventory(hooks)==desired, 'Selected inventory mismatch')
            c.require({p.name:c.regular(p) for p in backup.iterdir() if p.name!='selected-factory'}==initial['hookPrincipals'], 'Original backup changed')
            result.update(success=True,selected=str(selected),selectedPrincipal=selected_principal,desired=desired)
    except BaseException as error:
        result['error']=repr(error)
        # A rollback is admitted only against the complete known postimage.
        # Any foreign drift retains originals and the partial journal untouched.
        try:
            fixed_state()
            check_hooks()
            for name in reversed(result['changed'].copy()):
                fixed_state(); check_hooks()
                os.replace(name,name,src_dir_fd=backup_fd,dst_dir_fd=hooks_fd)
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
