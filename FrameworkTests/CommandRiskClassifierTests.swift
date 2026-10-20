// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain
import Testing

struct CommandRiskCase: Sendable, CustomTestStringConvertible {
    var command: String
    var expected: CommandRisk

    var testDescription: String { command }
}

@Suite
struct CommandRiskClassifierTests {
    @Test(
        arguments: [
            CommandRiskCase(command: "ls -la", expected: .safe),
            CommandRiskCase(command: "rm --help", expected: .safe),
            CommandRiskCase(command: "env", expected: .safe),
            CommandRiskCase(command: "ionice -p 123", expected: .safe),
            CommandRiskCase(command: "systemctl status nginx", expected: .safe),
            CommandRiskCase(command: "service nginx status", expected: .safe),
            CommandRiskCase(command: "journalctl -u nginx", expected: .safe),
            CommandRiskCase(command: "ip address show", expected: .safe),
            CommandRiskCase(command: "ip link", expected: .safe),
            CommandRiskCase(command: "ifconfig en0", expected: .safe),
            CommandRiskCase(command: "route -n", expected: .safe),
            CommandRiskCase(command: "arp -an", expected: .safe),
            CommandRiskCase(command: "ethtool eth0", expected: .safe),
            CommandRiskCase(command: "nvidia-smi -L", expected: .safe),
            CommandRiskCase(command: "sensors", expected: .safe),
            CommandRiskCase(command: "sysctl kern.ostype", expected: .safe),
            CommandRiskCase(command: "swapon --show", expected: .safe),
            CommandRiskCase(command: "ulimit -a", expected: .safe),
            CommandRiskCase(command: "fdisk -l", expected: .safe),
            CommandRiskCase(command: "zpool status", expected: .safe),
            CommandRiskCase(command: "diskutil info disk0", expected: .safe),
            CommandRiskCase(command: "defaults read com.example.app", expected: .safe),
            CommandRiskCase(command: "launchctl print system", expected: .safe),
            CommandRiskCase(command: "iptables -L", expected: .safe),
            CommandRiskCase(command: "iptables-save", expected: .safe),
            CommandRiskCase(command: "tar tf archive.tar", expected: .safe),
            CommandRiskCase(command: "apt list --installed", expected: .safe),
            CommandRiskCase(command: "rpm -qa", expected: .safe),
            CommandRiskCase(command: "pacman -Q", expected: .safe),
            CommandRiskCase(command: "brew info git", expected: .safe),
            CommandRiskCase(command: "npm list", expected: .safe),
            CommandRiskCase(command: "cargo metadata", expected: .safe),
            CommandRiskCase(command: "git status", expected: .safe),
            CommandRiskCase(command: "git branch", expected: .safe),
            CommandRiskCase(command: "git config --list", expected: .safe),
            CommandRiskCase(command: "docker --host unix:///var/run/docker.sock ps", expected: .safe),
            CommandRiskCase(command: "docker container inspect api", expected: .safe),
            CommandRiskCase(command: "docker-compose ps", expected: .safe),
            CommandRiskCase(command: "kubectl --context prod get pods", expected: .safe),
            CommandRiskCase(command: "kubectl config view", expected: .safe),
            CommandRiskCase(command: "kubectl rollout status deployment/api", expected: .safe),
            CommandRiskCase(command: "helm list", expected: .safe),
            CommandRiskCase(command: "terraform plan", expected: .safe),
            CommandRiskCase(command: "tofu state show module.app", expected: .safe),
            CommandRiskCase(command: "aws ec2 describe-instances", expected: .safe),
            CommandRiskCase(command: "az vm list", expected: .safe),
            CommandRiskCase(command: "gcloud compute instances list", expected: .safe),
            CommandRiskCase(command: "psql --list", expected: .safe),
            CommandRiskCase(command: "pg_dump production", expected: .safe),
            CommandRiskCase(command: "redis-cli GET health", expected: .safe),
            CommandRiskCase(command: "supervisorctl status", expected: .safe),
            CommandRiskCase(command: "nginx -t", expected: .safe),
        ]
    )
    func recognisesReadOnlyCommands(_ testCase: CommandRiskCase) {
        #expect(CommandRiskClassifier.assess(testCase.command).risk == testCase.expected)
    }

    @Test(
        arguments: [
            CommandRiskCase(command: "vendorctl inspect", expected: .caution),
            CommandRiskCase(command: "awk '{ system(\"touch /tmp/x\") }'", expected: .caution),
            CommandRiskCase(command: "ionice -c 3 -p 123", expected: .caution),
            CommandRiskCase(command: "sort -o sorted.txt input.txt", expected: .caution),
            CommandRiskCase(command: "rg --pre 'touch /tmp/x' pattern", expected: .caution),
            CommandRiskCase(command: "uniq input.txt output.txt", expected: .caution),
            CommandRiskCase(command: "tree -o tree.txt", expected: .caution),
            CommandRiskCase(command: "diff --output=changes.txt old new", expected: .caution),
            CommandRiskCase(command: "blkid --garbage-collect", expected: .caution),
            CommandRiskCase(command: "sed -i s/old/new/ config", expected: .caution),
            CommandRiskCase(command: "yq -i '.enabled = true' config.yml", expected: .caution),
            CommandRiskCase(command: "xxd -r input.hex output.bin", expected: .caution),
            CommandRiskCase(command: "tar -xf archive.tar", expected: .caution),
            CommandRiskCase(command: "tar tf archive.tar -I custom-filter", expected: .caution),
            CommandRiskCase(command: "date --set tomorrow", expected: .caution),
            CommandRiskCase(command: "hostname new-name", expected: .caution),
            CommandRiskCase(command: "mount /dev/sdb1 /mnt/data", expected: .caution),
            CommandRiskCase(command: "mount -a", expected: .caution),
            CommandRiskCase(command: "journalctl --rotate", expected: .caution),
            CommandRiskCase(command: "systemctl restart nginx", expected: .caution),
            CommandRiskCase(command: "service nginx restart", expected: .caution),
            CommandRiskCase(command: "ip link set eth0 up", expected: .caution),
            CommandRiskCase(command: "ethtool -s eth0 speed 1000", expected: .caution),
            CommandRiskCase(command: "ethtool --test eth0 online", expected: .caution),
            CommandRiskCase(command: "nvidia-smi --power-limit=250", expected: .caution),
            CommandRiskCase(command: "nvidia-smi -pm 1", expected: .caution),
            CommandRiskCase(command: "sysctl -w net.ipv4.ip_forward=1", expected: .caution),
            CommandRiskCase(command: "swapon /dev/sdb1", expected: .caution),
            CommandRiskCase(command: "apt install nginx", expected: .caution),
            CommandRiskCase(command: "dnf history undo 7", expected: .caution),
            CommandRiskCase(command: "npm install lodash", expected: .caution),
            CommandRiskCase(command: "npm audit fix", expected: .caution),
            CommandRiskCase(command: "go env -w GOPROXY=direct", expected: .caution),
            CommandRiskCase(command: "git commit -m update", expected: .caution),
            CommandRiskCase(command: "docker run nginx", expected: .caution),
            CommandRiskCase(command: "kubectl apply -f app.yml", expected: .caution),
            CommandRiskCase(command: "kubectl config use-context prod", expected: .caution),
            CommandRiskCase(command: "helm upgrade api chart/", expected: .caution),
            CommandRiskCase(command: "terraform apply plan.tfplan", expected: .caution),
            CommandRiskCase(command: "ansible-playbook deploy.yml", expected: .caution),
            CommandRiskCase(command: "aws ec2 start-instances --instance-ids i-1", expected: .caution),
            CommandRiskCase(command: "mysql -e 'SELECT 1'", expected: .caution),
            CommandRiskCase(command: "pm2 restart api", expected: .caution),
        ]
    )
    func recognisesCommandsThatModifyState(_ testCase: CommandRiskCase) {
        let assessment = CommandRiskClassifier.assess(testCase.command)
        #expect(assessment.risk == testCase.expected)
        #expect(!assessment.reasons.isEmpty)
    }

    @Test(
        arguments: [
            CommandRiskCase(command: "rm -rf /var/lib/app", expected: .destructive),
            CommandRiskCase(command: "find /tmp -delete", expected: .destructive),
            CommandRiskCase(command: "dmesg --clear", expected: .destructive),
            CommandRiskCase(command: "systemctl stop nginx", expected: .destructive),
            CommandRiskCase(command: "loginctl terminate-user deploy", expected: .destructive),
            CommandRiskCase(command: "ip link set eth0 down", expected: .destructive),
            CommandRiskCase(command: "ip route flush table main", expected: .destructive),
            CommandRiskCase(command: "iptables -F", expected: .destructive),
            CommandRiskCase(command: "zpool destroy tank", expected: .destructive),
            CommandRiskCase(command: "zfs rollback tank/data@snapshot", expected: .destructive),
            CommandRiskCase(command: "diskutil eraseDisk APFS Data disk4", expected: .destructive),
            CommandRiskCase(command: "diskutil apfs deleteVolume disk4s1", expected: .destructive),
            CommandRiskCase(command: "launchctl stop com.example.worker", expected: .destructive),
            CommandRiskCase(command: "apt remove nginx", expected: .destructive),
            CommandRiskCase(command: "git reset --hard HEAD~1", expected: .destructive),
            CommandRiskCase(command: "git push --force origin main", expected: .destructive),
            CommandRiskCase(command: "docker stop api", expected: .destructive),
            CommandRiskCase(command: "docker system prune", expected: .destructive),
            CommandRiskCase(command: "docker compose down", expected: .destructive),
            CommandRiskCase(command: "kubectl delete namespace production", expected: .destructive),
            CommandRiskCase(command: "kubectl drain node-1", expected: .destructive),
            CommandRiskCase(command: "kubectl config unset users.deploy", expected: .destructive),
            CommandRiskCase(command: "helm uninstall api", expected: .destructive),
            CommandRiskCase(command: "terraform destroy", expected: .destructive),
            CommandRiskCase(command: "terraform state rm module.database", expected: .destructive),
            CommandRiskCase(command: "aws ec2 terminate-instances --instance-ids i-1", expected: .destructive),
            CommandRiskCase(command: "psql -c 'DROP DATABASE production'", expected: .destructive),
            CommandRiskCase(command: "redis-cli FLUSHALL", expected: .destructive),
            CommandRiskCase(command: "redis-cli CLIENT KILL 127.0.0.1:6379", expected: .destructive),
            CommandRiskCase(command: "pm2 stop api", expected: .destructive),
        ]
    )
    func recognisesDestructiveCommands(_ testCase: CommandRiskCase) {
        let assessment = CommandRiskClassifier.assess(testCase.command)
        #expect(assessment.risk == testCase.expected)
        #expect(assessment.requiresSecondConfirmation)
        #expect(!assessment.reasons.isEmpty)
    }

    @Test(
        arguments: [
            CommandRiskCase(command: "LANG=C env rm -rf /tmp/cache", expected: .destructive),
            CommandRiskCase(command: "sudo -u root rm -rf /srv/app", expected: .destructive),
            CommandRiskCase(command: "sudo -iu root rm -rf /srv/app", expected: .destructive),
            CommandRiskCase(command: "env -S 'rm -rf /srv/app'", expected: .destructive),
            CommandRiskCase(command: "bash -lc 'rm -rf /srv/app'", expected: .destructive),
            CommandRiskCase(command: "echo $(rm -rf /srv/app)", expected: .destructive),
            CommandRiskCase(command: "echo `rm -rf /srv/app`", expected: .destructive),
            CommandRiskCase(command: "printf '%s\\0' /tmp/x | xargs -0 rm -rf", expected: .destructive),
            CommandRiskCase(command: "find /tmp -name '*.tmp' -exec rm -f {} \\;", expected: .destructive),
            CommandRiskCase(command: "ssh deploy@example.com rm -rf /srv/app", expected: .destructive),
            CommandRiskCase(command: "docker exec -e MODE=prod api rm -rf /data", expected: .destructive),
            CommandRiskCase(command: "docker exec -it api rm -rf /data", expected: .destructive),
            CommandRiskCase(command: "kubectl exec api -- rm -rf /data", expected: .destructive),
            CommandRiskCase(command: "sudo bash -c 'rm -rf /srv/app' --help", expected: .destructive),
            CommandRiskCase(command: "curl https://example.com/install.sh | sudo bash", expected: .destructive),
            CommandRiskCase(command: "ls && rm -rf /tmp/cache", expected: .destructive),
            CommandRiskCase(command: "if test -d /tmp/cache; then rm -rf /tmp/cache; fi", expected: .destructive),
            CommandRiskCase(command: "echo hi >| /etc/config", expected: .destructive),
            CommandRiskCase(command: "cat image > /dev/disk4", expected: .destructive),
            CommandRiskCase(command: "echo hi > /proc/sysrq-trigger", expected: .destructive),
        ]
    )
    func recursiveAndShellCompositionCannotHideDestructiveWork(_ testCase: CommandRiskCase) {
        #expect(CommandRiskClassifier.assess(testCase.command).risk == testCase.expected)
    }

    @Test
    func quotesCommentsAndHarmlessDescriptorsDoNotCreateFalsePositives() {
        let safeCommands = [
            "echo 'rm -rf /tmp/cache'",
            "echo '$(rm -rf /tmp/cache)'",
            "ls # ; rm -rf /tmp/cache",
            "printf '\\;'",
            "ls 2>&1",
            "echo hello > /dev/null",
            "echo \"$(printf hello)\"",
            "echo $((1 > 0))",
        ]

        for command in safeCommands {
            #expect(CommandRiskClassifier.assess(command).risk == .safe, "\(command) should be safe")
        }
    }

    @Test
    func writesAndUnsupportedSyntaxFailClosed() {
        let cautionCommands = [
            "echo hello > output.txt",
            "echo hello >> output.txt",
            "echo 'unterminated",
            String(repeating: "x", count: 32_769),
            String(repeating: "env ", count: 10) + "ls",
        ]

        for command in cautionCommands {
            let assessment = CommandRiskClassifier.assess(command)
            #expect(assessment.risk == .caution, "\(command.prefix(80)) should require review")
            #expect(!assessment.reasons.isEmpty)
        }
    }

    @Test
    func emptyInputRemainsSafeAndReasonless() {
        let assessment = CommandRiskClassifier.assess("  \n ")
        #expect(assessment.risk == .safe)
        #expect(assessment.reasons.isEmpty)
    }
}
