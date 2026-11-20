local draft = workspace.read(arg[1])
workspace.write(arg[2], string.upper(draft))
print(_VERSION)
