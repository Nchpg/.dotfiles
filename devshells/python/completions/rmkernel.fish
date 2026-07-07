function __jupyter_kernel_names
    for d in ~/.local/share/jupyter/kernels/*/
        basename $d
    end
end
complete -c rmkernel --no-files --arguments "(__jupyter_kernel_names)" -d "kernel jupyter"
