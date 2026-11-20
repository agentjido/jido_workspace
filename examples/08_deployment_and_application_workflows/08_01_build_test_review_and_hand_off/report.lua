local stage, input, product = arg[1], arg[2], arg[3]

if stage == "build" then
  print("building report")
  workspace.write(product, "REPORT\n" .. string.upper(workspace.read(input)))
elseif stage == "test" then
  print("testing report")
  assert(workspace.read(input) == workspace.read(product), "built report differs from expected")
  print("passed")
else
  error("unknown stage")
end
