const {execSync}=require('child_process'),cp=require('child_process');
function pkg(app){const o=execSync(`python tools/huawei_firmware_extractor.py "${app}" --list`,{encoding:'utf8'});
  return o.split('\n').filter(l=>/^\s*\d+\s/.test(l)).map(l=>l.trim().split(/\s+/)[1]).filter(Boolean);}
function tbl(img){const o=execSync(`node tools/gpt_parse.js "${img}"`,{encoding:'utf8'});
  return o.split('\n').filter(l=>/^p\s*\d/.test(l)).map(l=>{const f=l.trim().split(/\s+/);return f[2]||f[1];}).filter(Boolean);}
const P5=pkg('fw_b186/Software/dload/UPDATE.APP'),P8=pkg('fw_b379/dload/UPDATE.APP');
const T5=tbl('rb186/efi.img'),T8=tbl('emui8_b379/efi.img');
const KB=n=>({包条目数:P5.length,表分区数:T5.length});
function report(nm,P,T){
  const nof=new Set(P),notab=new Set(T);
  console.log(`\n### ${nm}: 包 ${P.length} 条 / 表 ${T.length} 个分区`);
  console.log('  包里有、表里没有(=写到表外区域):', [...nof].filter(x=>!notab.has(x)).join(' ')||'（无）');
  console.log('  表里有、包里没有(=只能依赖机上已有内容):');
  console.log('   ', [...notab].filter(x=>!nof.has(x)).join(' '));
}
report('B186 / EMUI 5.1',P5,T5);
report('B379 / EMUI 8.0',P8,T8);
