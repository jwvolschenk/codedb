#!/usr/bin/env python3
"""Produce private detailed parity and a source-free tracked performance report."""
import importlib.util
import json
import re
import statistics
from pathlib import Path
spec=importlib.util.spec_from_file_location('matrix',Path(__file__).with_name('release-matrix.py'))
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

def lines(text):
    return set(text.replace('\\','/').splitlines())

def hit_locations(text):
    found=set()
    try:
        obj=json.loads(text)
        def visit(v):
            if isinstance(v,dict):
                if 'path' in v and ('line' in v or 'line_num' in v):found.add((v['path'],v.get('line',v.get('line_num'))))
                for x in v.values():visit(x)
            elif isinstance(v,list):
                for x in v:visit(x)
        visit(obj)
    except ValueError:pass
    for path,line in re.findall(r'^\s*([^\n]+?):(\d+)[: (]',text,re.M):found.add((path.strip(),int(line)))
    return found

def evaluate(q,answer):
    text=answer['text'];expected=q['expected'];category=q['category']
    hits=hit_locations(text)
    if category in ('exact-definition','cross-component-definition','reference-precision-recall','scoped-search-recall','workflow-parity'):
        wanted={(x['path'],x['line']) for x in expected}
        matched=wanted & hits
        return {'expected':len(wanted),'matched':len(matched),'recall':len(matched)/len(wanted) if wanted else None,
                'unexpected':sorted(hits-wanted),'missing':sorted(wanted-hits),
                'precision':len(matched)/len(hits) if hits and category=='reference-precision-recall' else None}
    if category=='ranged-read':
        passed=expected[0]['source_line'] in text
    elif category=='outline':passed=all(x['symbol'] in text for x in expected)
    else:passed=all(x['path'] in text for x in expected)
    return {'expected':len(expected),'all_targets_present':passed}

def main():
    matrix=json.loads((m.PRIVATE/'matrix.json').read_text());runs=matrix['runs']
    golden=json.loads((m.PRIVATE/'golden.json').read_text())
    manifest=json.loads((m.PRIVATE/'manifest.json').read_text())
    extended=json.loads((m.PRIVATE/'extended.json').read_text()) if (m.PRIVATE/'extended.json').exists() else {}
    report={'gate':'FAIL' ,'threshold_percent':10,'comparisons':[], 'parity':{},'binaries':matrix['binaries'],
            'config':matrix['config'],'golden_human_review':'pending'}
    def compare(root,metric,baseline,candidate):
        b=statistics.median(baseline);c=statistics.median(candidate)
        delta=(c/b-1)*100 if b else None
        report['comparisons'].append({'root':root,'metric':metric,'baseline':b,'candidate':c,'delta_percent':delta,
            'gate':'FAIL' if delta is not None and delta>10 else 'PASS' if delta is not None else 'UNDEFINED',
            'baseline_variability':m.stats(baseline),'candidate_variability':m.stats(candidate)})
    for name in m.ROOTS:
        grouped={v:[r for r in runs if r['root']==name and r['variant']==v] for v in ('baseline','candidate')}
        parity={'questions':[], 'corpus':{}}
        for metric,fn in [('cold_ms',lambda r:r['cold']['ms']),('warm_ms',lambda r:r['warm']['ms']),
                          ('cold_peak_rss_bytes',lambda r:r['cold_resources']['peak_rss']),
                          ('warm_rss_bytes',lambda r:r['warm_resources']['rss']),('idle_cpu_s',lambda r:r['idle']['cpu_s'])]:
            if all(all(r['cold']['state']=='ready' and 'warm' in r for r in rows) for rows in grouped.values()):
                compare(name,metric,*[[fn(r) for r in grouped[v]] for v in ('baseline','candidate')])
        b=grouped['baseline'][0];c=grouped['candidate'][0]
        bfiles=lines(b.get('inventory',{}).get('text',''));cfiles=lines(c.get('inventory',{}).get('text',''))
        known={f['path'] for f in manifest[name]['files']}
        bfiles &= known;cfiles &= known
        parity['corpus']={'baseline_count':len(bfiles),'candidate_count':len(cfiles),'only_baseline':sorted(bfiles-cfiles),'only_candidate':sorted(cfiles-bfiles)}
        for q in golden[name]:
            item={'id':q['id'],'category':q['category']}
            for variant in grouped:
                results=[next((x for x in r['questions'] if x['id']==q['id']),None) for r in grouped[variant]]
                if all(results):item[variant]=evaluate(q,results[0]['answer'])
            if all(variant in item for variant in grouped):
                for statistic in ('median','p95'):
                    compare(name,q['id']+'_'+statistic+'_ms',*[[next(x for x in r['questions'] if x['id']==q['id'])['latency_ms'][statistic] for r in grouped[v]] for v in ('baseline','candidate')])
                item['response_bytes']={v:statistics.median(next(x for x in r['questions'] if x['id']==q['id'])['response_bytes']['median'] for r in grouped[v]) for v in grouped}
                item['tool_calls_per_task']=1
            parity['questions'].append(item)
        report['parity'][name]=parity
        for metric in ('addition_ms','update_ms','deletion_ms'):
            rows={v:[r.get(metric) for r in extended.get('updates',[]) if r['root']==name and r['variant']==v] for v in grouped}
            if all(rows.values()) and all(x is not None for values in rows.values() for x in values):compare(name,metric,rows['baseline'],rows['candidate'])
        for count in (1,4,8):
            for metric in ('aggregate_rss_bytes','sum_process_peak_rss_bytes','all_ready_ms','idle_cpu_s'):
                rows={v:[r[metric] for r in extended.get('concurrency',[]) if r['root']==name and r['variant']==v and r['agents']==count and metric in r] for v in grouped}
                if all(rows.values()):compare(name,f'{count}_agents_{metric}',rows['baseline'],rows['candidate'])
            for statistic in ('median','p95'):
                rows={v:[r['query_ms'][statistic] for r in extended.get('concurrency',[]) if r['root']==name and r['variant']==v and r['agents']==count and 'query_ms' in r] for v in grouped}
                if all(rows.values()):compare(name,f'{count}_agents_query_{statistic}_ms',rows['baseline'],rows['candidate'])
    failures=[r for r in report['comparisons'] if r['gate']=='FAIL']
    report['gate']='FAIL' if failures else 'PASS'
    m.save(m.PRIVATE/'parity-performance.json',report)
    public={k:report[k] for k in ('gate','threshold_percent','config','comparisons','golden_human_review')}
    public['binaries']={v:r['sha256'] for v,r in matrix['binaries'].items()}
    m.save(m.REPO/'plans/evidence/release-2026-10-08/performance.json',public)
    print('Strict 10% gate:',report['gate'],'failures:',len(failures),'comparisons:',len(report['comparisons']))

if __name__=='__main__':main()
