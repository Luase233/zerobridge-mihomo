package mobile

import "strings"

// Rule intentionally excludes payloads: mobile only needs the outbound group.
type Rule struct {
	Type  string `json:"type"`
	Proxy string `json:"proxy"`
}

func applyRouting(s *State, proxies map[string]Proxy, rules []Rule, known bool) {
	s.RoutingKnown = known && (s.Mode == "rule" || s.Mode == "global" || s.Mode == "direct")
	scores := map[string]int{}
	var visit func(string, int, map[string]bool)
	visit = func(name string, weight int, seen map[string]bool) {
		if seen[name] || len(seen) > 64 {
			return
		}
		p, exists := proxies[name]
		if !exists || len(p.All) == 0 {
			return
		}
		seen[name] = true
		scores[name] += weight
		if p.Type == "LoadBalance" {
			for _, child := range p.All {
				visit(child, weight, seen)
			}
		} else {
			visit(p.Now, weight, seen)
		}
		delete(seen, name)
	}
	switch s.Mode {
	case "global":
		visit("GLOBAL", 100000, map[string]bool{})
	case "rule":
		if known {
			for _, r := range rules {
				weight := 1
				if strings.EqualFold(r.Type, "MATCH") {
					weight = 100000
				}
				visit(r.Proxy, weight, map[string]bool{})
			}
		}
	}
	best := 0
	for i := range s.Groups {
		g := &s.Groups[i]
		g.RoutingUsed = scores[g.Name] > 0
		switch {
		case s.Mode == "direct":
			g.RoutingNote = "当前是直连模式，代理组选择不影响直连出站"
		case s.Mode == "rule" && !known:
			g.RoutingNote = "未能读取规则，无法确认此组是否参与出站"
		case s.Mode == "rule" && g.RoutingUsed:
			g.RoutingNote = "规则可使用此组；实际出站取决于匹配规则和新连接"
		case s.Mode == "rule" && g.Name == "GLOBAL":
			g.RoutingNote = "当前是规则模式，规则未引用 GLOBAL；切换此组通常不改变出站"
		case g.RoutingUsed:
			g.RoutingNote = "当前模式可使用此组；已有连接可能继续使用原节点"
		default:
			g.RoutingNote = "当前模式的选择链未使用此组；选择已保存，但可能不改变出站"
		}
		if g.Selectable && scores[g.Name] > best {
			s.PreferredGroup, best = g.Name, scores[g.Name]
		}
	}
	if s.Mode == "global" && scores["GLOBAL"] > 0 {
		s.PreferredGroup = "GLOBAL"
	}
}
