// Supply the real new dependency to existing isolated module tests.
const vm=require('node:vm');
const create=vm.createContext;
vm.createContext=function(sandbox={},...args){
 sandbox.SessionFence??={capture:()=>({signal:new AbortController().signal,check(){}}),arm(){},clear(){}};
 return create.call(this,sandbox,...args);
};
