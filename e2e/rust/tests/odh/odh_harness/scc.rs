// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

//! Pure checks for namespace-allocated identities (never changes SCCs).

use std::collections::BTreeSet;

use serde_json::Value;

#[derive(Debug)]
pub struct Allocation(Vec<(u32, u32)>);

impl Allocation {
    pub fn parse(value: &str) -> Result<Self, String> {
        let mut ranges = Vec::new();
        for block in value.split(',') {
            let (start, size) = block
                .trim()
                .split_once('/')
                .ok_or_else(|| format!("invalid SCC allocation {value:?}"))?;
            let start: u32 = start
                .parse()
                .map_err(|_| format!("invalid allocation {value:?}"))?;
            let size: u32 = size
                .parse()
                .map_err(|_| format!("invalid allocation {value:?}"))?;
            let end = start
                .checked_add(size.checked_sub(1).ok_or("empty allocation")?)
                .ok_or("allocation overflow")?;
            ranges.push((start, end));
        }
        Ok(Self(ranges))
    }

    pub fn require(&self, id: u32, context: &str) -> Result<(), String> {
        if self
            .0
            .iter()
            .any(|&(start, end)| (start..=end).contains(&id))
        {
            Ok(())
        } else {
            Err(format!(
                "{context}: identity {id} outside allocation {self:?}"
            ))
        }
    }

    pub fn require_disjoint(&self, other: &Self) -> Result<(), String> {
        if self
            .0
            .iter()
            .any(|&(a, b)| other.0.iter().any(|&(c, d)| a <= d && c <= b))
        {
            Err(format!(
                "workspace SCC allocations overlap: {self:?}, {other:?}"
            ))
        } else {
            Ok(())
        }
    }
}

pub fn annotation<'a>(namespace: &'a Value, key: &str) -> Result<&'a str, String> {
    namespace["metadata"]["annotations"][key]
        .as_str()
        .filter(|s| !s.trim().is_empty())
        .ok_or_else(|| format!("namespace {} missing {key}", namespace["metadata"]["name"]))
}

/// Normalize the category set from either a namespace MCS level or a full
/// process security context, including compressed `SELinux` category notation.
pub fn categories(label: &str) -> Result<BTreeSet<u32>, String> {
    let level = label
        // procfs security attributes may be NUL-terminated, unlike namespace
        // annotation strings. Keep the same parser for both sources.
        .trim_matches(|c: char| c.is_whitespace() || c == '\0')
        .split_once("s0:")
        .map(|(_, value)| value)
        .ok_or_else(|| format!("missing MCS categories in {label:?}"))?;
    let mut result = BTreeSet::new();
    for category in level.split(',') {
        let parse = |s: &str| -> Result<u32, String> {
            s.strip_prefix('c')
                .and_then(|s| s.parse().ok())
                .ok_or_else(|| format!("invalid MCS category in {label:?}"))
        };
        let (start, end) = if let Some((start, end)) = category.split_once('.') {
            (parse(start)?, parse(end)?)
        } else {
            let n = parse(category)?;
            (n, n)
        };
        if start > end {
            return Err(format!("reversed MCS category range in {label:?}"));
        }
        result.extend(start..=end);
    }
    Ok(result)
}

pub fn check_pod_identity(pod: &Value, uid: &Allocation, gid: &Allocation) -> Result<(), String> {
    let context = format!(
        "pod {}/{}",
        pod["metadata"]["namespace"], pod["metadata"]["name"]
    );
    let pod_sc = &pod["spec"]["securityContext"];
    let containers = pod["spec"]["containers"]
        .as_array()
        .filter(|c| !c.is_empty())
        .ok_or_else(|| format!("{context}: no containers"))?;
    for container in containers.iter().chain(
        pod["spec"]["initContainers"]
            .as_array()
            .into_iter()
            .flatten(),
    ) {
        for (key, allocation) in [("runAsUser", uid), ("runAsGroup", gid)] {
            let value = &container["securityContext"][key];
            let effective = if value.is_null() { &pod_sc[key] } else { value };
            let id = effective
                .as_u64()
                .and_then(|id| u32::try_from(id).ok())
                .ok_or_else(|| {
                    format!("{context}/{}: missing effective {key}", container["name"])
                })?;
            allocation.require(id, &format!("{context}/{} {key}", container["name"]))?;
        }
    }
    for id in pod_sc["fsGroup"].as_u64().into_iter().chain(
        pod_sc["supplementalGroups"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|v| v.as_u64().unwrap_or(u64::MAX)),
    ) {
        gid.require(
            u32::try_from(id).map_err(|_| format!("{context}: invalid group {id}"))?,
            &context,
        )?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn allocation_boundaries_and_overlap() {
        let a = Allocation::parse("100/10,200/2").unwrap();
        for id in [100, 109, 200, 201] {
            a.require(id, "test").unwrap();
        }
        for id in [99, 110, 199, 202] {
            assert!(a.require(id, "test").is_err());
        }
        assert!(
            a.require_disjoint(&Allocation::parse("109/2").unwrap())
                .is_err()
        );
        a.require_disjoint(&Allocation::parse("110/90").unwrap())
            .unwrap();
        for value in ["", "100", "100/0", "4294967295/2", "x/10"] {
            assert!(Allocation::parse(value).is_err(), "{value}");
        }
    }

    #[test]
    fn mcs_comparison_uses_sets_not_order_or_spelling() {
        assert_eq!(
            categories("s0:c1,c2").unwrap(),
            categories("system_u:system_r:container_t:s0:c2,c1").unwrap()
        );
        assert_eq!(
            categories("s0:c1.c3").unwrap(),
            categories("s0:c3,c1,c2").unwrap()
        );
        assert_eq!(
            categories("system_u:system_r:container_t:s0:c19,c29\0\n").unwrap(),
            categories("s0:c29,c19").unwrap()
        );
        assert_ne!(
            categories("s0:c1,c2").unwrap(),
            categories("s0:c2,c3").unwrap()
        );
        for value in ["s0", "s0:", "s0:c3.c1", "s0:c4294967296", "s0:c1,invalid"] {
            assert!(categories(value).is_err(), "{value}");
        }
    }

    #[test]
    fn checks_container_overrides_and_groups() {
        let range = Allocation::parse("100/10").unwrap();
        let mut pod = json!({"spec": {"securityContext": {"runAsUser": 100, "runAsGroup": 101, "fsGroup": 102, "supplementalGroups": [103]}, "containers": [{"name": "workload"}]}});
        check_pod_identity(&pod, &range, &range).unwrap();
        pod["spec"]["containers"][0]["securityContext"] = json!({"runAsUser": 99});
        assert!(check_pod_identity(&pod, &range, &range).is_err());
        pod["spec"]["containers"][0]["securityContext"] = json!({});
        pod["spec"]["securityContext"]["fsGroup"] = json!(99);
        assert!(check_pod_identity(&pod, &range, &range).is_err());
        assert!(annotation(&json!({}), "openshift.io/sa.scc.uid-range").is_err());
    }

    #[test]
    fn uid_and_gid_allocations_are_independent_and_init_containers_are_checked() {
        let uid = Allocation::parse("100/10").unwrap();
        let gid = Allocation::parse("200/10").unwrap();
        let mut pod = json!({"spec": {
            "securityContext": {"runAsUser": 100, "runAsGroup": 200},
            "containers": [{"name": "workload"}],
            "initContainers": [{"name": "bootstrap", "securityContext": {"runAsUser": 101, "runAsGroup": 201}}]
        }});
        check_pod_identity(&pod, &uid, &gid).unwrap();
        pod["spec"]["initContainers"][0]["securityContext"]["runAsGroup"] = json!(100);
        assert!(check_pod_identity(&pod, &uid, &gid).is_err());
        pod["spec"]["initContainers"] = json!([]);
        pod["spec"]["securityContext"]["runAsUser"] = Value::Null;
        assert!(check_pod_identity(&pod, &uid, &gid).is_err());
    }
}
